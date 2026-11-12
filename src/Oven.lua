-- Soft Bun's Oven (sbo), by softbuns :: bakes raw Materia Magica output into something edible (Mudlet 5.x)
--   formats eq / items / score / affects, compares gear, prompt gauge bar.
--   (formerly "MMFormat", then "SoftbunsOS")
--
-- How it works:
--   * Watches commands you send (eq, look <thing>, identify ...).
--   * Captures the lines the game sends back, until the next prompt
--     (or a short pause when no prompt is detected).
--   * Prints a formatted version in the main window and/or a floating
--     Inspector window.
--
-- Type `sbo` in Mudlet for the list of commands (`oven` works too).

sbo = sbo or oven or {}
oven = sbo           -- old name, kept so older links/commands still work
local M = sbo

M.version = "0.68.0"
M.settingsFile = getMudletHomeDir() .. "/oven_settings.lua"
M.samplesFile  = getMudletHomeDir() .. "/oven_samples.txt"

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------
M.defaults = {
  enabled      = true,
  main         = "replace",  -- replace | keep | off   (what to do in the main window)
  window       = true,       -- show the floating Inspector window
  idle         = 0.4,        -- seconds of silence that ends a capture when no prompt is seen
  maxTime      = 4,          -- hard limit on how long a capture can last
  maxLines     = 120,
  samples      = true,       -- write raw captures to oven_samples.txt (for tuning the parsers)
  recWindow    = 300,        -- blocks of recent game output kept in memory (0 = off); saved on demand / on death
  fontSize     = 10,
  -- Lua pattern for your prompt, used in addition to telnet GA/EOR detection.
  -- Default: a line that is just <...> containing a digit, e.g. "<120hp 80sp 90st>".
  promptPattern = "^%s*<[^>]*%d[^>]*>%s*$",
  updateCheck  = true,       -- on login, quietly check GitHub for a newer version
  autoUpdate   = false,      -- check every 2 minutes and install new versions automatically
  questHudSide = "right",    -- quest HUD corner: right or left (top of the game text area)
  questHudOpacity = 100,     -- quest HUD background opacity, 0-100
  questHudBlurb = false,     -- show each quest's description (hints) in the HUD
  questAutoPin = true,       -- a quest you take with quest request goes straight onto the quest HUD
  pickupLook   = true,
  signLook     = true,       -- look quietly at a signpost the first time you're in its room (its run names)       -- look quietly at items you pick up that Oven doesn't know yet
  combatLines  = true,       -- combat mode mxp: a line per round (the game shows none) and a summary per fight
  combatBar    = true,       -- combat mode mxp: a line above the prompt bar with your targets' health, while you fight
  map          = false,      -- follow your room (GMCP) on the map and walk where you double-click
  mapPanel     = false,      -- the map in its own Oven window
  autocompare  = true,       -- compare looked-at items with what you wear in that slot
  bar          = false,      -- move the prompt into a fixed bar at the bottom
  barMode      = "gauges",   -- gauges | raw
  barWidth     = 10,         -- length of each gauge in the prompt bar
  barBg        = { 12, 12, 16 },  -- prompt bar background (r, g, b): a faint tint
  barSession   = false,      -- session stats: on the bar when they fit, else their own line
  barSessionPos = "top",     -- where that line goes: top of the screen, or bottom (under the bar)
  barSessionStyle = "full",  -- full: time · k/d · xp/hr   short: just xp/hr
  barBlank     = true,       -- with the bar on, also drop the blank line before each prompt
  helpWindow   = true,       -- game `help` (and `sbo`) output goes to its own window
  -- which tabs also show on the main screen: Inspector results (Oven's layout), help pages (as sent),
  -- the Log tab's reports, chat lines (off: chat is taken off the main screen, kept in the Chat tab)
  mirror       = { view = true, help = false, log = false, chat = true },
  tabs         = true,       -- the Inspector window has tabs: Inspector | Help | Log (help pages open there)
  tabAuto      = true,       -- whatever arrives brings its tab to the front (off: the tab gets a • instead)
  slotNames    = "short",    -- short | full  (equipment slot names in eq / creature tables)
  showEmpty    = true,       -- list empty equipment slots in eq
  showDonation = true,       -- include empty donation-only slots (amulets, face, aura)
  gameColors   = true,       -- keep the game's own colours on item names
  eqStats      = true,       -- AR / affects column in eq, from items you have looked at
  barLines     = 1,
  barFont      = 0,          -- 0 = same size as the main window
}

M.cfg = M.cfg or {}
local function migrate(newFile, oldName)
  local old = getMudletHomeDir() .. "/" .. oldName
  if not io.exists(newFile) and io.exists(old) then
    local i = io.open(old, "rb"); local data = i:read("*a"); i:close()
    local o = io.open(newFile, "wb"); o:write(data); o:close()
  end
end

function M.loadSettings()
  migrate(M.settingsFile, "softbunsos_settings.lua")
  migrate(M.settingsFile, "mmformat_settings.lua")
  local t = {}
  if io.exists(M.settingsFile) then pcall(table.load, M.settingsFile, t) end
  t.updatePath = nil  -- old local-file updater setting
  -- earlier defaults were too strong: move anyone still on one of them to the current default
  if type(t.barBg) == "table" then
    local c = table.concat(t.barBg, ",")
    if c == "28,30,42" or c == "18,19,26" then t.barBg = nil end
  end
  for k, v in pairs(M.defaults) do
    if t[k] == nil then t[k] = v end
  end
  -- mirror: its own table per profile, with any tab added later filled in
  local m = {}
  for k, v in pairs(M.defaults.mirror) do m[k] = v end
  for k, v in pairs(type(t.mirror) == "table" and t.mirror or {}) do m[k] = v end
  if t.helpBoth then m.help = true end   -- 0.30.1's sbo helpwindow both
  t.mirror, t.helpBoth = m, nil
  M.cfg = t
end
function M.saveSettings() table.save(M.settingsFile, M.cfg) end

---------------------------------------------------------------------------
-- Database (oven.db, Mudlet's built-in SQLite): items, loot, kills, deaths and what's in
-- each room. Rows are added or changed one at a time - nothing is ever rewritten whole -
-- and only what's needed is read.
---------------------------------------------------------------------------
M.dbFile = getMudletHomeDir() .. "/oven.db"

-- a Lua value as Lua source (tables of strings/numbers/booleans), and back
local function ser(v)
  local t = type(v)
  if t == "string" then return string.format("%q", v)
  elseif t == "number" or t == "boolean" then return tostring(v)
  elseif t ~= "table" then return "nil" end
  local parts, n = {}, #v
  for i = 1, n do parts[#parts + 1] = ser(v[i]) end
  for k, x in pairs(v) do
    if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
      parts[#parts + 1] = "[" .. ser(k) .. "]=" .. ser(x)
    end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
local function deser(s)
  if type(s) ~= "string" or s == "" then return nil end
  local f = loadstring("return " .. s)
  if not f then return nil end
  setfenv(f, {})
  local ok, v = pcall(f)
  return ok and v or nil
end
M.ser, M.deser = ser, deser

-- "Shop,Trainer" -> { "Shop", "Trainer" }
local function splitTags(s)
  local t = {}
  for x in tostring(s or ""):gmatch("[^,]+") do t[#t + 1] = x end
  return t
end

local function sq(v)
  if v == nil then return "NULL"
  elseif type(v) == "number" then return tostring(v)
  elseif type(v) == "boolean" then return v and "1" or "0" end
  return "'" .. (tostring(v):gsub("'", "''")) .. "'"
end
-- "... %s ..." with each value quoted for SQL
local function sql(fmt, ...)
  local args = { ... }
  for i = 1, select("#", ...) do args[i] = sq(args[i]) end
  return string.format(fmt, unpack(args, 1, select("#", ...)))
end

local SCHEMA = {
  "CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT)",
  "CREATE TABLE IF NOT EXISTS items (name TEXT PRIMARY KEY, type TEXT, level INTEGER, worn TEXT, seen INTEGER, data TEXT)",
  "CREATE TABLE IF NOT EXISTS item_stats (name TEXT, stat TEXT, value REAL)",
  "CREATE INDEX IF NOT EXISTS item_stats_name ON item_stats (name)",
  "CREATE INDEX IF NOT EXISTS item_stats_stat ON item_stats (stat)",
  "CREATE TABLE IF NOT EXISTS loot (id INTEGER PRIMARY KEY, t INTEGER, who TEXT, item TEXT, src TEXT, n INTEGER, room INTEGER, room_name TEXT, area TEXT)",
  "CREATE INDEX IF NOT EXISTS loot_room ON loot (room)",
  "CREATE TABLE IF NOT EXISTS kills (id INTEGER PRIMARY KEY, t INTEGER, key TEXT, name TEXT, room INTEGER, n INTEGER DEFAULT 1, exp INTEGER DEFAULT 0)",
  "CREATE INDEX IF NOT EXISTS kills_room ON kills (room)",
  "CREATE INDEX IF NOT EXISTS kills_key ON kills (key)",
  "CREATE TABLE IF NOT EXISTS deaths (id INTEGER PRIMARY KEY, t INTEGER, room INTEGER, level INTEGER, total INTEGER, recap TEXT)",
  "CREATE INDEX IF NOT EXISTS deaths_room ON deaths (room)",
  "CREATE TABLE IF NOT EXISTS room_npcs (room INTEGER, key TEXT, text TEXT, tags TEXT, seen INTEGER, last INTEGER, PRIMARY KEY (room, key))",
  "CREATE TABLE IF NOT EXISTS room_flags (room INTEGER PRIMARY KEY, tags TEXT, last INTEGER)",
  "CREATE TABLE IF NOT EXISTS room_enters (room INTEGER, cmd TEXT, dest INTEGER, last INTEGER, PRIMARY KEY (room, cmd))",
  "CREATE TABLE IF NOT EXISTS marks (name TEXT PRIMARY KEY, room INTEGER, t INTEGER)",
  -- signposts: the room it stands in, the post's name and its run destinations ("rune=south;towerofart=south")
  -- shops: what each shop's list showed last time (shop list / shop i), by the room it's in
  "CREATE TABLE IF NOT EXISTS shops (room INTEGER PRIMARY KEY, name TEXT, last INTEGER)",
  "CREATE TABLE IF NOT EXISTS shop_items (room INTEGER, no INTEGER, item TEXT, level INTEGER, amount TEXT, cost INTEGER, last INTEGER, PRIMARY KEY (room, item))",
  "CREATE INDEX IF NOT EXISTS shop_items_item ON shop_items (item)",
  -- a shopkeeper who won't sell to you ("…cannot sell my wares to someone of your level…"), and your level then
  "CREATE TABLE IF NOT EXISTS shop_refusals (room INTEGER PRIMARY KEY, said TEXT, level INTEGER, t INTEGER)",
  -- the game's "where is": each area's feature list, and where each feature is (worked out on the map from
  -- the directions the game gives; start + dirs kept too)
  "CREATE TABLE IF NOT EXISTS where_features (area TEXT, feature TEXT, PRIMARY KEY (area, feature))",
  "CREATE TABLE IF NOT EXISTS where_rooms (area TEXT, feature TEXT, room INTEGER, start INTEGER, dirs TEXT, t INTEGER, PRIMARY KEY (area, feature))",
  -- your notes (the Notes tab), each with where you were when you wrote it
  "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY, t INTEGER, text TEXT, room INTEGER, room_name TEXT, area TEXT)",
  "CREATE TABLE IF NOT EXISTS signposts (room INTEGER PRIMARY KEY, sign TEXT, dests TEXT, exact INTEGER, last INTEGER)",
}

local SCHEMA_ADD = {
  "ALTER TABLE room_npcs ADD COLUMN src TEXT",   -- 0.23.0: which kind of block it was read from
  "ALTER TABLE kills ADD COLUMN vnum INTEGER",    -- 0.24.0: the mob's number and race, from GMCP
  "ALTER TABLE kills ADD COLUMN race TEXT",
  "ALTER TABLE deaths ADD COLUMN killer TEXT",    -- 0.24.0: what you were fighting
  "ALTER TABLE shop_items ADD COLUMN currency TEXT", -- 0.59.0: "gold", "rewardunits", …
}

function M.dbOpen()
  if M.dbConn then return M.dbConn end
  if not luasql or not luasql.sqlite3 then return nil end
  M.dbEnv = M.dbEnv or luasql.sqlite3()
  local conn, err = M.dbEnv:connect(M.dbFile)
  if not conn then M.log("<red>[sbo] can't open " .. M.dbFile .. ": " .. tostring(err) .. "<reset>"); return nil end
  M.dbConn = conn
  conn:execute("PRAGMA journal_mode=WAL")
  conn:execute("PRAGMA synchronous=NORMAL")
  for _, s in ipairs(SCHEMA) do conn:execute(s) end
  -- columns added later (an error just means the column is already there)
  for _, s in ipairs(SCHEMA_ADD) do pcall(function() conn:execute(s) end) end
  if M.signMigrate then pcall(M.signMigrate) end
  return conn
end

function M.dbClose()
  if M.dbConn then pcall(function() M.dbConn:close() end); M.dbConn = nil end
end

-- run a statement; returns true or nil, error
function M.dbx(fmt, ...)
  local conn = M.dbOpen()
  if not conn then return nil, "no database" end
  local q = sql(fmt, ...)
  local res, err = conn:execute(q)
  if not res then
    if M.cfg and M.cfg.samples then M.log("<dim_grey>[sbo] db: " .. tostring(err) .. "<reset>") end
    return nil, err
  end
  if type(res) == "userdata" or type(res) == "table" then pcall(function() res:close() end) end
  return true
end

-- all rows of a query, as tables keyed by column name
function M.dbRows(fmt, ...)
  local conn = M.dbOpen()
  if not conn then return {} end
  local cur = conn:execute(sql(fmt, ...))
  if not cur or type(cur) == "number" then return {} end
  local rows = {}
  local row = cur:fetch({}, "a")
  while row do
    rows[#rows + 1] = row
    row = cur:fetch({}, "a")
  end
  cur:close()
  return rows
end

function M.dbRow(fmt, ...) return M.dbRows(fmt, ...)[1] end

function M.dbGet(key)
  local r = M.dbRow("SELECT value FROM kv WHERE key = %s", key)
  return r and deser(r.value)
end
function M.dbSet(key, value)
  M.dbx("INSERT OR REPLACE INTO kv (key, value) VALUES (%s, %s)", key, ser(value))
end

function M.dbLastId()
  local r = M.dbRow("SELECT last_insert_rowid() AS id")
  return r and tonumber(r.id)
end

-- One-time move of the older files into the database: oven_world.lua (0.18), the same data
-- inside oven_settings.lua (before 0.18) and oven_items.lua. The files are kept, renamed
-- to *.migrated.
local OLD_WORLD_KEYS = { "loot", "kills", "roomNpcs", "roomFlags", "roomEnters", "roomKills", "roomDeaths" }
function M.importOld()
  if not M.dbOpen() then return end
  local worldFile = getMudletHomeDir() .. "/oven_world.lua"
  local w = {}
  if io.exists(worldFile) then pcall(table.load, worldFile, w) end
  local fromSettings = false
  for _, k in ipairs(OLD_WORLD_KEYS) do
    if M.cfg[k] ~= nil then
      if w[k] == nil then w[k] = M.cfg[k] end
      M.cfg[k] = nil
      fromSettings = true
    end
  end
  local items = {}
  if io.exists(M.itemsFile) then pcall(table.load, M.itemsFile, items) end
  if not next(w) and not next(items) then return end
  M.cleanRoomNpcs(w.roomNpcs)
  M.dbx("BEGIN")
  -- loot, oldest first
  for _, e in ipairs(w.loot or {}) do
    M.dbx("INSERT INTO loot (t, who, item, src, n, room, room_name, area) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
      e.t, e.who, e.item, e.from, e.count or 1, e.room, e.roomName, e.area)
  end
  -- kills: the per-room counts become rows in their rooms; the rest of each creature's
  -- all-time count (and all its exp) goes in one row with no room
  local inRooms = {}
  for room, book in pairs(w.roomKills or {}) do
    for key, e in pairs(book) do
      M.dbx("INSERT INTO kills (t, key, name, room, n, exp) VALUES (%s, %s, %s, %s, %s, 0)", e.last, key, e.name, tonumber(room), e.count)
      inRooms[key] = (inRooms[key] or 0) + (e.count or 0)
    end
  end
  for key, e in pairs(w.kills or {}) do
    M.dbx("INSERT INTO kills (t, key, name, room, n, exp) VALUES (%s, %s, %s, NULL, %s, %s)",
      e.last, key, e.name, math.max(0, (e.count or 0) - (inRooms[key] or 0)), e.exp or 0)
  end
  for room, list in pairs(w.roomDeaths or {}) do
    for _, d in ipairs(list) do
      M.dbx("INSERT INTO deaths (t, room, level, total) VALUES (%s, %s, %s, %s)", d.t, tonumber(room), d.level, d.total)
    end
  end
  for room, book in pairs(w.roomNpcs or {}) do
    for key, n in pairs(book) do
      M.dbx("INSERT OR REPLACE INTO room_npcs (room, key, text, tags, seen, last) VALUES (%s, %s, %s, %s, %s, %s)",
        tonumber(room), key, n.text, table.concat(n.tags or {}, ","), n.seen or 1, n.last)
    end
  end
  for room, f in pairs(w.roomFlags or {}) do
    M.dbx("INSERT OR REPLACE INTO room_flags (room, tags, last) VALUES (%s, %s, %s)", tonumber(room), table.concat(f.tags or {}, ","), f.last)
  end
  for room, book in pairs(w.roomEnters or {}) do
    for cmd, e in pairs(book) do
      M.dbx("INSERT OR REPLACE INTO room_enters (room, cmd, dest, last) VALUES (%s, %s, %s, %s)", tonumber(room), cmd, e.to, e.last)
    end
  end
  for _, it in pairs(items.items or {}) do if it.name then M.storeItem(it) end end
  if items.recent then M.dbSet("recent", items.recent) end
  if items.eq then M.dbSet("eq", items.eq) end
  if items.pinned then M.dbSet("pinned", items.pinned) end
  M.dbx("COMMIT")
  if io.exists(worldFile) then os.rename(worldFile, worldFile .. ".migrated") end
  if io.exists(M.itemsFile) then os.rename(M.itemsFile, M.itemsFile .. ".migrated") end
  if fromSettings then M.saveSettings() end
end

-- the samples log is for tuning layouts; keep it from growing without end
function M.rotateSamples()
  local f = io.open(M.samplesFile, "r")
  if not f then return end
  local size = f:seek("end")
  f:close()
  if size and size > 2 * 1024 * 1024 then
    local old = M.samplesFile:gsub("%.txt$", ".old.txt")
    os.remove(old)
    os.rename(M.samplesFile, old)
  end
end

-- Which commands start a capture. Checked against the lower-cased command.
-- Return a kind ("eq", "item", "contents") or nil.
local directions = { n=1,s=1,e=1,w=1,u=1,d=1,ne=1,nw=1,se=1,sw=1,
  north=1,south=1,east=1,west=1,up=1,down=1,northeast=1,northwest=1,southeast=1,southwest=1 }

-- Command words, matched the way the game does: any abbreviation of `word`
-- at least `min` letters long.  `except` lists abbreviations that the game
-- gives to a different command (e.g. "equip" is not "equipment").
-- kind = which layout to use; kinds without a layout are only logged.
M.commands = {
  { word = "equipment", min = 2, kind = "eq",       except = { equip = true } },
  { word = "inventory", min = 1, kind = "contents", target = "inventory" },
  { word = "look",      min = 1, kind = "item",     needsArgs = true },
  { word = "examine",   min = 2, kind = "item",     needsArgs = true },  -- bare "ex" (exits) is ignored
  { word = "identify",  min = 2, kind = "item",     needsArgs = true },
  { word = "lore",      min = 3, kind = "item",     needsArgs = true },
  { word = "score",     min = 2, kind = "score" },    -- "sc" is score in Materia Magica
  { word = "affects",   min = 2, kind = "affects" },
  { word = "help",      min = 3, kind = "help" },     -- shown as-is in the help window
  -- recorded (not reformatted yet) so a practice planner can be built from real output
  { word = "level",     min = 3, kind = "levels" },
  { word = "levels",    min = 6, kind = "levels" },
  { word = "skills",    min = 3, kind = "skills" },
  { word = "skill",     min = 3, kind = "skills" },
  { word = "practice",  min = 3, kind = "skills" },
  { word = "train",     min = 3, kind = "skills" },
  -- recorded only (shown as the game sends it) until a layout exists
  { word = "quest",     min = 3, kind = "quest" },
  { word = "alias",     min = 5, kind = "aliases", needsNoArgs = true },
  -- "where is" / "where is food": read for the area's features and where they are; shown as the game sends it
  { word = "where",     min = 5, kind = "where",
    argsOk = function(r) return r == "is" or r:match("^is%s") ~= nil end },
  -- a shop's list ("shop list", "sh li", "sh i"): read into the shops table; shown as the game sends it
  { word = "shop",      min = 2, kind = "shop",
    argsOk = function(r) return r ~= "" and (("list"):sub(1, #r) == r or ("inventory"):sub(1, #r) == r) end },
}

function M.classify(cmd)
  local c = cmd:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local verb, rest = c:match("^(%S+)%s*(.-)$")
  if not verb or verb == "" then return nil end
  if verb == "?" then return "help", rest end
  for _, def in ipairs(M.commands) do
    if #verb >= def.min and def.word:sub(1, #verb) == verb and not (def.except and def.except[verb]) then
      if def.needsArgs and rest == "" then return nil end
      if def.needsNoArgs and rest ~= "" then return nil end
      if def.argsOk and not def.argsOk(rest) then return nil end
      if def.word == "look" or def.word == "examine" then
        if directions[rest] then return nil end
        local inside = rest:match("^in%s+(.+)$")
        if inside then return "contents", inside end
        rest = rest:gsub("^at%s+", "")
      end
      return def.kind, def.target or rest
    end
  end
  if (verb == "c" or ("cast"):sub(1, #verb) == verb) and rest:match("^'?ident") then
    return "item", (rest:gsub("^'?identify'?%s*", ""))
  end
  return nil
end

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function trim(s) s = s:gsub("^%s+", ""); s = s:gsub("%s+$", ""); return s end

-- print an Oven line in the main window: a line break first only when the last line
-- already has text on it (a prompt, say), so there's never an empty line before it
function M.log(text)
  -- while a game line is being handled, a message waits until it's done: printing moves the cursor,
  -- and the prompt bar's deleteLine() would then delete the message instead of the prompt
  if M.inLine then
    tempTimer(0, function() M.log(text) end)
    return
  end
  local cur = ""
  pcall(function() moveCursorEnd("main"); cur = getCurrentLine("main") or "" end)
  cecho("main", ((cur ~= "") and "\n" or "") .. text .. "\n")
end
local function now() return (getEpoch and getEpoch()) or os.clock() end
local function rtrim(s) return (s:gsub("%s+$", "")) end
local function ulen(s) return (utf8 and utf8.len(s)) or #s end
local function pad(s, n) return s .. string.rep(" ", math.max(0, n - ulen(s))) end
local unpack = table.unpack or unpack

local C = {
  title  = "gold",
  rule   = "dim_grey",
  key    = "khaki",
  slot   = "light_sky_blue",
  text   = "light_grey",
  item   = "white",
  num    = "cyan",
  plus   = "pale_green",
  minus  = "tomato",
  dim    = "dim_grey",
  flag   = "orange",
}

-- colour a single word
local function wordColor(w, base)
  if w:match("^%(.*%)$") or w:match("^%[.*%]$") then return C.flag end
  if w:match("^%+%d") then return C.plus end
  if w:match("^%-%d") then return C.minus end
  if w:match("%d") then return C.num end
  return base
end

-- Word wrap `text` into segments lines. Returns list of lines (each a list of {color,text}).
-- first: segments placed before the first line (already rendered prefix, width `firstW`)
local function wrapWords(text, width, indent, base, prefix, prefixW)
  local lines = {}
  local cur = prefix and { unpack(prefix) } or {}
  local curW = prefixW or 0
  local startW = curW
  for word in text:gmatch("%S+") do
    local wl = ulen(word)
    if curW > startW and curW + 1 + wl > width then
      lines[#lines + 1] = cur
      cur = { { C.text, string.rep(" ", indent) } }
      curW, startW = indent, indent
    end
    if curW > startW then
      cur[#cur + 1] = { base, " " }
      curW = curW + 1
    end
    cur[#cur + 1] = { wordColor(word, base), word }
    curW = curW + wl
  end
  lines[#lines + 1] = cur
  return lines
end

local function addAll(dst, src) for _, l in ipairs(src) do dst[#dst + 1] = l end end

---------------------------------------------------------------------------
-- Parsers / formatters.  Each returns a list of lines (list of {color,text}).
---------------------------------------------------------------------------
M.formatters = {}

-- "<worn on head>   a battered helm"  /  "[head]  a helm"
-- "<worn on head>   a battered helm" -> "worn on head", "a battered helm"
-- (Materia Magica always uses <...>; the slot name must be words, so "<1hp 1sp 1st>" isn't one)
local function parseSlot(l)
  local slot, item = l:match("^%s*<([%a][%a ']*)>%s*(.-)%s*$")
  if slot and item ~= "" then return trim(slot), item end
end

-- "Key: value" detection
local function parseKV(chunk)
  local k, v = chunk:match("^%s*([%a][%w '%-/%.]-)%s*:%s*(.*)$")
  if k and ulen(k) <= 24 and select(2, k:gsub("%S+", "")) <= 4 and not k:match("%.%s") then
    return trim(k), trim(v)
  end
end

-- split a line into "Key: value" fields separated by 2+ spaces; nil if not all fields are KV
local function splitKVLine(l)
  local fields = {}
  for chunk in (trim(l) .. "  "):gmatch("(.-)%s%s+") do
    if chunk ~= "" then fields[#fields + 1] = chunk end
  end
  if #fields == 0 then return nil end
  local res = {}
  for _, f in ipairs(fields) do
    local k, v = parseKV(f)
    if not k then return nil end
    res[#res + 1] = { k, v }
  end
  return res
end

-- Does a block of lines look like server-wrapped prose (vs. a list)?
local function looksWrapped(block)
  -- columns (3+ spaces between words) mean a table, never prose; the game puts two spaces
  -- after a full stop in prose, so that alone doesn't count
  local columns = 0
  for _, l in ipairs(block) do if l:match("%S%s%s%s+%S") then columns = columns + 1 end end
  if columns > 0 and columns >= #block / 3 then return false end
  if #block < 2 then return ulen(block[1] or "") > 60 end
  local maxL = 0
  for _, l in ipairs(block) do maxL = math.max(maxL, ulen(l)) end
  if maxL < 50 then return false end
  local long = 0
  for i = 1, #block - 1 do
    if ulen(block[i]) >= maxL * 0.7 then long = long + 1 end
  end
  return long >= (#block - 1) * 0.75
end

function M.formatters.generic(raw, width)
  -- 1. group into paragraphs separated by blank lines
  local paras, cur = {}, {}
  for _, l in ipairs(raw) do
    if trim(l) == "" then
      if #cur > 0 then paras[#paras + 1] = cur; cur = {} end
    else
      cur[#cur + 1] = rtrim(l)
    end
  end
  if #cur > 0 then paras[#paras + 1] = cur end

  -- 2. find KV width across the whole text so values line up
  local keyW = 0
  for _, p in ipairs(paras) do
    for _, l in ipairs(p) do
      local kv = splitKVLine(l)
      if kv then for _, f in ipairs(kv) do keyW = math.max(keyW, ulen(f[1])) end end
    end
  end
  keyW = math.min(keyW, 20)

  local out = {}
  local function flushBlock(block)
    if #block == 0 then return end
    if looksWrapped(block) then
      local text = table.concat(block, " ")
      addAll(out, wrapWords(text, width, 0, C.text))
    else
      for _, l in ipairs(block) do
        if l:match("%S%s%s%s+%S") and ulen(l) <= width then
          out[#out + 1] = { { C.text, l } }   -- columns: keep the game's spacing
        else
          addAll(out, wrapWords(l, width, 2, C.text))
        end
      end
    end
  end

  for pi, p in ipairs(paras) do
    if pi > 1 then out[#out + 1] = {} end
    local block = {}
    for _, l in ipairs(p) do
      local kv = splitKVLine(l)
      if kv then
        flushBlock(block); block = {}
        for _, f in ipairs(kv) do
          local pre = { { C.key, pad(f[1], keyW) }, { C.dim, " : " } }
          addAll(out, wrapWords(f[2], width, keyW + 3, C.item, pre, keyW + 3))
        end
      else
        block[#block + 1] = l
      end
    end
    flushBlock(block)
  end
  return out
end

---------------------------------------------------------------------------
-- Materia Magica specific layouts.  Anything a parser does not recognise is
-- still printed (as plain text) so nothing from the game is ever lost.
---------------------------------------------------------------------------
local function segLen(segs) local n = 0 for _, s in ipairs(segs) do n = n + ulen(s[2]) end return n end
local function blank(out) if #out > 0 and #out[#out] > 0 then out[#out + 1] = {} end end
local function subhead(out, text)
  blank(out)
  out[#out + 1] = { { C.title, "▸ " .. text } }
end

-- trailing "(new) (unlit)" -> name, {"new","unlit"}
local function stripConds(s)
  local conds = {}
  while true do
    local body, c = s:match("^(.-)%s*%(([^()]+)%)%s*$")
    if not body or body == "" then break end
    table.insert(conds, 1, c); s = body
  end
  return s, conds
end

local goodCond = { new = true, fresh = true, perfect = true, excellent = true, pristine = true }
local function condSegs(conds)
  local segs = {}
  for _, c in ipairs(conds) do
    local col = goodCond[c:lower()] and "dark_sea_green" or (c:match("lit") and C.dim or C.flag)
    segs[#segs + 1] = { col, " (" .. c .. ")" }
  end
  return segs
end

-- The game's own colours. M.curDecho holds the captured lines with colour codes
-- (index-aligned with the plain lines the formatter is given).
-- decho line -> runs { {rgb or nil, text}, ... }
function M.dechoRuns(d)
  local runs, cur, i = {}, nil, 1
  local function add(txt)
    if txt == "" then return end
    local last = runs[#runs]
    if last and last[1] == cur then last[2] = last[2] .. txt else runs[#runs + 1] = { cur, txt } end
  end
  while i <= #d do
    local s1, e1, tag = d:find("^<([^<>]*)>", i)
    if s1 and (tag:match("^%d+,%d+,%d+") or tag:match("^:") or tag == "r" or tag:match("^/?[biuso]$")) then
      local r, g, b = tag:match("^(%d+),(%d+),(%d+)")
      if r then cur = { tonumber(r), tonumber(g), tonumber(b) } elseif tag == "r" then cur = nil end
      i = e1 + 1
    else
      local nxt = d:find("<", i + 1, true) or (#d + 1)
      add(d:sub(i, nxt - 1)); i = nxt
    end
  end
  return runs
end

-- substring by characters (Mudlet's utf8 has sub; plain Lua's doesn't)
function M.usub(str, i, j)
  if utf8 and utf8.sub then return utf8.sub(str, i, j) end
  if utf8 and utf8.offset then
    local bi = utf8.offset(str, i) or (#str + 1)
    local bj = (utf8.offset(str, j + 1) or (#str + 1)) - 1
    return str:sub(bi, bj)
  end
  return str:sub(i, j)
end

-- the runs covering `text` inside the line `idx` of the current capture, or nil
function M.runsFor(idx, text)
  if not M.cfg.gameColors or not M.curDecho or not idx or not M.curDecho[idx] or not text or text == "" then return nil end
  local plainLine = M.curPlain and M.curPlain[idx]
  if not plainLine then return nil end
  local at = plainLine:find(text, 1, true)
  if not at then return nil end
  local from = (utf8 and utf8.len(plainLine:sub(1, at - 1))) or (at - 1)
  local to = from + ((utf8 and utf8.len(text)) or #text)
  local runs = M.dechoRuns(M.curDecho[idx])
  -- "plain" colour: the first visible (non-space) text before the item on this line,
  -- else the first visible text of the capture's first line (e.g. "You are carrying:").
  -- Leading spaces don't count: the game may start an item's colour before them.
  local function firstVisible(rs, limit)
    local p = 0
    for _, run in ipairs(rs) do
      local n = (utf8 and utf8.len(run[2])) or #run[2]
      local upto = limit and math.min(n, limit - p) or n
      if upto > 0 and M.usub(run[2], 1, upto):find("%S") then return run[1], true end
      p = p + n
      if limit and p >= limit then break end
    end
    return nil, false
  end
  local base, found = firstVisible(runs, from)
  if not found then
    for j = 1, #M.curDecho do
      if j ~= idx then
        local b2, f2 = firstVisible(M.dechoRuns(M.curDecho[j]))
        if f2 then base = b2; break end
      end
    end
  end
  local out, pos, coloured = {}, 0, false
  for _, run in ipairs(runs) do
    local n = (utf8 and utf8.len(run[2])) or #run[2]
    local a, b = math.max(pos, from), math.min(pos + n, to)
    if a < b then
      local piece = M.usub(run[2], a - pos + 1, b - pos)
      local same = (run[1] == nil and base == nil) or (run[1] and base and run[1][1] == base[1] and run[1][2] == base[2] and run[1][3] == base[3])
      if not same then coloured = true end
      out[#out + 1] = { same and C.item or run[1], piece }
    end
    pos = pos + n
  end
  return coloured and out or nil
end

-- the game's colours for `text` on capture line `idx`, exactly as sent
function M.runsExact(idx, text)
  if not M.cfg.gameColors or not M.curDecho or not idx or not M.curDecho[idx] or not text or text == "" then return nil end
  local plainLine = M.curPlain and M.curPlain[idx]
  local at = plainLine and plainLine:find(text, 1, true)
  if not at then return nil end
  local from = ulen(plainLine:sub(1, at - 1))
  local to = from + ulen(text)
  local out, pos = {}, 0
  for _, run in ipairs(M.dechoRuns(M.curDecho[idx])) do
    local n = ulen(run[2])
    local a, b = math.max(pos, from), math.min(pos + n, to)
    if a < b then
      local c = run[1]
      local plain = not c or (c[1] == 192 and c[2] == 192 and c[3] == 192)
      out[#out + 1] = { plain and C.text or c, M.usub(run[2], a - pos + 1, b - pos) }
    end
    pos = pos + n
  end
  return #out > 0 and out or nil
end

-- which armor location a worn position protects (nil when the game doesn't make that clear)
function M.arLocationFor(worn)
  if not worn then return nil end
  local w = worn:lower()
  for _, pair in ipairs({ { "head", "head" }, { "body", "torso" }, { "torso", "torso" }, { "arms", "arms" },
                          { "legs", "legs" }, { "tail", "tail" } }) do
    if w:find(pair[1], 1, true) then return pair[2] end
  end
end

-- the game's colour of `sub` on capture line `idx` (first visible character), or nil
function M.colorAt(idx, sub)
  local runs = M.runsExact(idx, sub)
  if not runs then return nil end
  for _, r in ipairs(runs) do
    if r[2]:find("%S") then return type(r[1]) == "table" and r[1] or nil end
  end
end

local function itemSegs(text, runs)
  local name, conds = stripConds(text)
  local segs = runs or { { C.item, name } }
  for _, c in ipairs(condSegs(conds)) do segs[#segs + 1] = c end
  return segs
end

-- key  value  (value given as segments; wraps long values with a hanging indent)
local function kvLine(out, key, keyW, segs, width)
  local pre = { { C.key, pad(key, keyW) }, { C.dim, "  " } }
  local indent = keyW + 2
  if segs[1] and segs[1][2]:match("^ +$") then indent = indent + ulen(segs[1][2]) + 2 end
  local cur, curW = { unpack(pre) }, keyW + 2
  for _, s in ipairs(segs) do
    local col, txt = s[1], s[2]
    if curW + ulen(txt) <= width then
      cur[#cur + 1] = s; curW = curW + ulen(txt)
    elseif indent + ulen(trim(txt)) <= width and curW > indent then
      out[#out + 1] = cur
      cur = { { C.text, string.rep(" ", indent) }, { col, trim(txt) } }
      curW = indent + ulen(trim(txt))
    else -- word wrap this segment
      local first = true
      for sp, word in txt:gmatch("(%s*)(%S+)") do
        local piece = sp .. word
        if curW + ulen(piece) > width and curW > indent then
          out[#out + 1] = cur
          cur, curW = { { C.text, string.rep(" ", indent) } }, indent
          piece = word
        end
        cur[#cur + 1] = { col, piece }; curW = curW + ulen(piece)
        first = false
      end
    end
  end
  out[#out + 1] = cur
end

-- short key/value cells laid out in two columns when there is room
local function grid(out, cells, width)
  if #cells == 0 then return end
  local kw, vw = 0, 0
  for _, c in ipairs(cells) do kw = math.max(kw, ulen(c[1])); vw = math.max(vw, segLen(c[2])) end
  local cellW = kw + 2 + vw
  local twoCol = width >= cellW * 2 + 3
  local i = 1
  while i <= #cells do
    local c = cells[i]
    local row = { { C.key, pad(c[1], kw) }, { C.dim, "  " } }
    for _, s in ipairs(c[2]) do row[#row + 1] = s end
    if twoCol and cells[i + 1] then
      row[#row + 1] = { C.text, string.rep(" ", vw - segLen(c[2]) + 3) }
      local d = cells[i + 1]
      row[#row + 1] = { C.key, pad(d[1], kw) }; row[#row + 1] = { C.dim, "  " }
      for _, s in ipairs(d[2]) do row[#row + 1] = s end
      i = i + 2
    else
      i = i + 1
    end
    out[#out + 1] = row
  end
end

local function numSegs(n, suffix)
  local col = tostring(n):match("^%-") and C.minus or C.num
  return { { col, tostring(n) }, suffix and { C.text, suffix } or nil }
end

-- "Affects agility by 1." -> {"+1 agility"} segments
local function affectSegs(what, by, nameColor)
  local n = tonumber(by) or 0
  local sign = n >= 0 and "+" or ""
  return { { n >= 0 and C.plus or C.minus, sign .. by }, { nameColor or C.item, " " .. what } }
end

local function prose(out, lines, width)
  if #lines == 0 then return end
  local text = table.concat(lines, " "):gsub("%s+", " ")
  addAll(out, wrapWords(trim(text), width, 0, C.text))
end

-- split "Sentence one. Sentence two." into sentences
local function sentences(t)
  local res = {}
  for s in (t:gsub("([%.!?])%s+(%u)", "%1\n%2") .. "\n"):gmatch("(.-)\n") do
    if trim(s) ~= "" then res[#res + 1] = trim(s) end
  end
  return res
end

---------------------------------------------------------------- weapons (eq + item)
local function parseWeaponSummary(s)
  local w = { summary = s, stats = {} }
  w.dmgLevel, w.dmgType = s:match("deal (%a+) ([%a%-]+) damage")
  w.accuracy = s:match("with (%a+) accuracy")
  w.range = s:match("at (%a+) range")
  w.critChance, w.critMult = s:match("with a (%a+) chance to crit for (%S+) damage")
  return w
end

-- "7 Damage: (+20 from weapon) (+-12 from skill & strength)"
local function parseWeaponStat(t)
  local val, label, src = t:match("^(%-?%d+%%?) ([%a ]-):%s*(.*)$")
  if not val then return nil end
  local parts = {}
  for num, why in src:gmatch("%(([+%-]+%d+) (.-)%)") do
    local n = num:gsub("^%+%-", "-"):gsub("^%-%+", "-")
    parts[#parts + 1] = { n, (why:gsub("^from ", "")) }
  end
  return { label, val, parts }
end

local function renderWeapon(out, w, width)
  local cells = {}
  if w.dmgLevel then cells[#cells + 1] = { "Damage", { { C.num, w.dmgLevel }, { C.text, " " .. w.dmgType } } } end
  if w.accuracy then cells[#cells + 1] = { "Accuracy", { { C.num, w.accuracy } } } end
  if w.range then cells[#cells + 1] = { "Range", { { C.num, w.range } } } end
  if w.critChance then cells[#cells + 1] = { "Crit", { { C.num, w.critChance }, { C.text, " (" .. w.critMult .. ")" } } } end
  if #cells > 0 then grid(out, cells, width) else prose(out, { w.summary }, width) end
  if #w.stats > 0 then
    blank(out)
    local lw = 0
    for _, st in ipairs(w.stats) do lw = math.max(lw, ulen(st[1])) end
    for _, st in ipairs(w.stats) do
      local segs = { { C.num, string.format("%-4s", st[2]) } }
      for i, p in ipairs(st[3]) do
        segs[#segs + 1] = { C.dim, i == 1 and " " or " · " }
        segs[#segs + 1] = { p[1]:match("^%-") and C.minus or C.plus, p[1] }
        segs[#segs + 1] = { C.text, " " .. p[2] }
      end
      kvLine(out, st[1], lw, segs, width)
    end
  end
end

---------------------------------------------------------------- equipment
-- Equipment slots (from HELP EQUIPMENT SLOTS plus what eq actually prints).
-- names: every spelling the game uses for the slot; n: how many; only: race/donation notes
M.slotTable = {
  { key = "spellbook", names = { "studying spellbook" }, extra = true },  -- seen on creatures
  { key = "tome",      names = { "studying tome" }, extra = true },
  { key = "light",     names = { "used as light", "illuminating" } },
  { key = "finger",    names = { "worn on finger" }, n = 2 },
  { key = "neck",      names = { "worn around neck" }, n = 2 },
  { key = "amulet",    names = { "amulet around neck" }, n = 2, only = "donation" },
  { key = "torso",     names = { "worn on body", "worn on torso" } },
  { key = "head",      names = { "worn on head" } },
  { key = "face",      names = { "worn over face" }, only = "donation" },
  { key = "legs",      names = { "worn on legs" } },
  { key = "feet",      names = { "worn on feet" } },
  { key = "hands",     names = { "worn on hands" } },
  { key = "arms",      names = { "worn on arms" } },
  { key = "shield",    names = { "worn as shield" } },
  { key = "quiver",    names = { "slung quiver" }, extra = true },
  { key = "wing (L)",  names = { "worn on left wing" }, only = "wings" },
  { key = "wing (R)",  names = { "worn on right wing" }, only = "wings" },
  { key = "cloak",     names = { "worn about body", "over shoulders" } },
  { key = "aura",      names = { "worn around body", "encompassing" }, only = "donation" },
  { key = "waist",     names = { "worn about waist", "worn around waist" } },
  { key = "hip",       names = { "worn on hip", "held on hip" } },
  { key = "tail",      names = { "worn on tail" }, only = "tail" },
  { key = "wrist",     names = { "worn around wrist" }, n = 2 },
  { key = "hand (R)",  names = { "right hand", "wielded" } },
  { key = "hand (L)",  names = { "left hand", "held" } },
}
M.slotByName = {}
for _, sl in ipairs(M.slotTable) do
  for _, n in ipairs(sl.names) do M.slotByName[n] = sl end
end
local function slotLabel(name)
  if M.cfg.slotNames == "full" then return name end
  local sl = M.slotByName[name:lower()]
  return sl and sl.key or name
end

-- what a worn item does for you, from Oven's memory of `look`:
-- a list of units ({segs}), e.g. {AR 1} {+1 agility} {+1 saving-spell}; nil if never looked at
local function itemStatUnits(name)
  local it = M.items and M.items[name]
  if not it then return nil end
  local units = {}
  if it.ar then units[#units + 1] = { { C.key, "AR " }, { C.num, tostring(it.ar) } } end
  local sums, order = {}, {}
  for _, list in ipairs({ it.affects or {}, it.relicAffects or {} }) do
    for _, af in ipairs(list) do
      if not sums[af[1]] then order[#order + 1] = af[1] end
      sums[af[1]] = (sums[af[1]] or 0) + (tonumber(af[2]) or 0)
    end
  end
  for _, k in ipairs(order) do
    local v = sums[k]
    units[#units + 1] = { { v >= 0 and C.plus or C.minus, (v >= 0 and "+" or "") .. v }, { C.item, " " .. k } }
  end
  if #units == 0 then units[1] = { { C.dim, "—" } } end
  return units
end

-- lay units out in a column of `avail` characters; returns lines of segments
local function flowUnits(units, avail)
  local lines, cur, w = {}, {}, 0
  for _, u in ipairs(units) do
    local uw = segLen(u)
    local sep = (#cur > 0) and 2 or 0
    if #cur > 0 and w + sep + uw > avail then
      lines[#lines + 1] = cur; cur, w, sep = {}, 0, 0
    end
    if sep > 0 then cur[#cur + 1] = { C.dim, "  " } end
    addAll(cur, u); w = w + sep + uw
  end
  if #cur > 0 then lines[#lines + 1] = cur end
  return lines
end

local function renderSlots(out, slots, width, withStats)
  local slotW = 0
  for _, r in ipairs(slots) do slotW = math.max(slotW, ulen(slotLabel(r[1]))) end
  slotW = math.min(slotW, 22)
  local indent = slotW + 3
  -- stats column starts after the longest item name that leaves room for them
  local statCol
  if withStats then
    local longest = 0
    for _, r in ipairs(slots) do
      if not r.empty then longest = math.max(longest, segLen(itemSegs(r[2]))) end
    end
    statCol = indent + math.min(longest, math.max(16, width - indent - 24)) + 2
  end
  local prev
  for _, r in ipairs(slots) do
    local sl = M.slotByName[r[1]:lower()]
    local group = sl and sl.key or r[1]
    local label = (group == prev) and "" or slotLabel(r[1])
    prev = group
    local pre = { { r.empty and C.dim or C.slot, pad(label, slotW) }, { C.dim, " │ " } }
    local segs
    if r.empty then
      segs = r.donation and { { C.dim, "empty · donation-only slot" } } or { { C.flag, "empty" } }
    else
      segs = itemSegs(r[2], r.runs)
    end
    local row = { unpack(pre) }
    local nameW = indent + segLen(segs)
    if nameW <= width then
      for _, sg in ipairs(segs) do row[#row + 1] = sg end
      out[#out + 1] = row
    else
      addAll(out, wrapWords(r[2] or "", width, indent, C.item, pre, indent))
      row = out[#out]; nameW = segLen(row)
    end
    if withStats and not r.empty then
      local units = itemStatUnits((stripConds(r[2])))
      local cont = { { C.text, string.rep(" ", slotW) }, { C.dim, " │ " } }
      if not units then
        -- never looked at: a small "?" after the name (or under it if there's no room)
        if nameW + 3 <= width then
          row[#row + 1] = { C.text, string.rep(" ", math.max(2, statCol - nameW)) }
          if nameW + 2 > statCol then row[#row] = { C.text, "  " } end
          row[#row + 1] = { C.dim, "?" }
        end
      else
        local lines = flowUnits(units, math.max(10, width - statCol))
        local first = 1
        if nameW + 2 <= statCol then
          row[#row + 1] = { C.text, string.rep(" ", statCol - nameW) }
          addAll(row, lines[1]); first = 2
        end
        for i = first, #lines do
          local l = { unpack(cont) }
          l[#l + 1] = { C.text, string.rep(" ", statCol - indent) }
          addAll(l, lines[i])
          out[#out + 1] = l
        end
      end
    end
  end
end

-- prose with paragraph breaks ("" entries split paragraphs). Lines are only joined
-- when they look like text the game wrapped; otherwise each line stays its own line.
local function paragraphs(out, lines, width)
  local cur = {}
  local function flush()
    if #cur == 0 then return end
    blank(out)
    if looksWrapped(cur) then prose(out, cur, width)
    else
      for _, l in ipairs(cur) do
        if (l:match("%S%s%s%s+%S") or l:match("^%s%s%s%s+%S")) and ulen(l) <= width then
          out[#out + 1] = { { C.text, l } }   -- columns / indented continuation: keep the game's spacing
        else
          prose(out, { l }, width)
        end
      end
    end
    cur = {}
  end
  for _, l in ipairs(lines) do
    if trim(l) == "" then flush() else cur[#cur + 1] = l end
  end
  flush()
end

local eqMisc = {
  { "^Your value if CPKed would be (.-)%.?$", function(v) return "CPK value", { { C.num, v } } end },
  { "^You have a (%d+%%) chance to resist a critical hit%.?$",
    function(v) return "Crit resist", { { C.num, v } } end },
  { "^You have a (%d+%%) chance to reduce spell damage taken by (%d+%%)%.?$",
    function(c, r) return "Spell ward", { { C.num, c }, { C.text, " chance to cut spell damage by " }, { C.num, r } } end },
}

function M.formatters.eq(raw, width)
  local slots, ar, misc, weapons, other = {}, {}, {}, {}, {}
  local slotW, header = 0, nil
  local weapon
  for idx, l in ipairs(raw) do
    local t = trim(l)
    local slot, item = parseSlot(l)
    local arLoc, arVal, arRest = t:match("^%((%a[%a ]-)%s*%)%s+(%-?%d+)%s*(.*)$")
    if t == "" or t:match("^You are using:?$") or t:match("^Current Armor Resistance")
       or t:match("^Equipped weapon damage") then
      -- section headings are re-drawn by us
    elseif slot then
      slots[#slots + 1] = { slot, item, runs = M.runsFor(idx, (stripConds(item))) }; slotW = math.max(slotW, ulen(slot))
    elseif arLoc then
      ar[#ar + 1] = { arLoc, arVal, arRest:match("([%d%.]+)%%") }
    elseif t:match("^With .-, you will deal") then
      weapon = parseWeaponSummary(t)
      weapon.name = t:match("^With (.-), you will deal")
      weapons[#weapons + 1] = weapon
    elseif weapon and parseWeaponStat(t) then
      weapon.stats[#weapon.stats + 1] = parseWeaponStat(t)
    else
      local matched = false
      for _, s in ipairs(sentences(t)) do
        local hit
        for _, m in ipairs(eqMisc) do
          local a, b = s:match(m[1])
          if a then misc[#misc + 1] = { m[2](a, b) }; hit = true; break end
        end
        if not hit then other[#other + 1] = s end
      end
    end
  end
  if #slots == 0 then return M.formatters.generic(raw, width) end

  local out = {}
  -- worn items and empty slots in one list, in the game's slot order
  -- (empty rows are what CHECK EQUIPMENT MISSING would tell you)
  local bySlot, unknown = {}, {}
  for _, r in ipairs(slots) do
    local sl = M.slotByName[r[1]:lower()]
    if sl then bySlot[sl.key] = bySlot[sl.key] or {}; table.insert(bySlot[sl.key], r)
    else unknown[#unknown + 1] = r end
  end
  local hasTail, hasWings = bySlot["tail"], bySlot["wing (L)"] or bySlot["wing (R)"]
  for _, a in ipairs(ar) do
    if a[1]:lower():match("tail") then hasTail = true end
    if a[1]:lower():match("wing") then hasWings = true end
  end
  local rows = {}
  for _, sl in ipairs(M.slotTable) do
    local worn = bySlot[sl.key] or {}
    for _, r in ipairs(worn) do rows[#rows + 1] = r end
    local applies = M.cfg.showEmpty and not sl.extra
      and (sl.only ~= "donation" or M.cfg.showDonation)
      and (sl.only ~= "tail" or hasTail) and (sl.only ~= "wings" or hasWings)
    if applies then
      for _ = #worn + 1, (sl.n or 1) do
        rows[#rows + 1] = { sl.names[1], nil, empty = true, donation = sl.only == "donation" }
      end
    end
  end
  for _, r in ipairs(unknown) do rows[#rows + 1] = r end   -- slots we don't know: still shown
  renderSlots(out, rows, width, M.cfg.eqStats)

  if #ar > 0 then
    -- damage reduction per AR point, measured from this eq (0.75% at the moment)
    local sumAR, sumPct = 0, 0
    for _, a in ipairs(ar) do
      if tonumber(a[2]) and tonumber(a[3]) and tonumber(a[2]) > 0 then
        sumAR = sumAR + tonumber(a[2]); sumPct = sumPct + tonumber(a[3])
      end
    end
    if sumAR > 0 then M.cfg.arRate = sumPct / sumAR end
    M.cfg.arLoc = {}
    for _, a in ipairs(ar) do M.cfg.arLoc[a[1]:lower()] = tonumber(a[2]) end
    -- body-location totals as a small table (each is the sum of everything protecting that location)
    local total = 0
    for _, a in ipairs(ar) do total = total + (tonumber(a[2]) or 0) end
    local cw = 8
    for _, a in ipairs(ar) do cw = math.max(cw, ulen(a[1]) + 2) end
    local function cell(txt) return string.format("%" .. cw .. "s", txt) end
    -- the lowest AR is highlighted rather than spelled out
    local low
    for _, a in ipairs(ar) do local n = tonumber(a[2]); if n and (not low or n < low) then low = n end end
    local function weakest(a) return tonumber(a[2]) == low end
    local head = { { C.title, pad("Armor", 10) } }
    local arRow = { { C.key, pad("AR", 10) } }
    local dmgRow = { { C.key, pad("damage", 10) } }
    for _, a in ipairs(ar) do
      local w = weakest(a)
      head[#head + 1] = { w and C.flag or C.slot, cell(a[1]:lower()) }
      arRow[#arRow + 1] = { w and C.flag or C.num, cell(tostring(a[2])) }
      dmgRow[#dmgRow + 1] = { w and C.flag or C.text, cell(tonumber(a[3]) and ("%-" .. string.format("%.2f", tonumber(a[3]))) or "") }
    end
    head[#head + 1] = { C.dim, cell("total") }
    arRow[#arRow + 1] = { C.num, cell(tostring(total)) }
    blank(out)
    if 10 + cw * (#ar + 1) <= width then
      out[#out + 1] = head; out[#out + 1] = arRow; out[#out + 1] = dmgRow
    else
      -- too narrow for columns: one location per line
      for _, a in ipairs(ar) do
        local w = weakest(a)
        out[#out + 1] = { { w and C.flag or C.slot, pad(a[1]:lower(), 10) }, { w and C.flag or C.num, string.format("%3s", a[2]) },
          { w and C.flag or C.text, tonumber(a[3]) and ("   %-" .. string.format("%.2f", tonumber(a[3])) .. " damage") or "" } }
      end
      out[#out + 1] = { { C.dim, pad("total", 10) }, { C.num, string.format("%3s", total) } }
    end
  end

  if #misc > 0 then
    subhead(out, "Defense")
    local kw = 0
    for _, m in ipairs(misc) do kw = math.max(kw, ulen(m[1])) end
    for _, m in ipairs(misc) do kvLine(out, m[1], kw, m[2], width) end
  end

  for _, w in ipairs(weapons) do
    subhead(out, "Weapon: " .. w.name)
    renderWeapon(out, w, width)
  end

  if #other > 0 then
    blank(out)
    for _, o in ipairs(other) do prose(out, { o }, width) end
  end
  return out
end

---------------------------------------------------------------- item look
-- extra one-line facts that some item types show.  Returns {label, segments} or nil.
M.itemExtras = {
  { "^This level (%d+) item has no special attributes%.?$", function(l) return "@level", l end },
  { "^Contains the level (%d+) spells? of (.-)%.?$",
    function(l, sp) return "Spell", { { C.slot, sp }, { C.dim, "  level " }, { C.num, l } } end },
  { "^Contains knowledge of the spell of (.-), scribed at level (%d+)%.?$",
    function(sp, l) return "Spell", { { C.slot, sp }, { C.dim, "  scribed at level " }, { C.num, l } } end },
  { "^%*Your level must be less than or equal to (%d+) to use this item%.?%s*(.-)$",
    function(l, e) return "Max level", { { C.num, l }, { C.dim, (e ~= "" and ("  " .. e) or "") } } end },
  { "^%*Your level must be at least (%d+) to use this item%.?%s*(.-)$",
    function(l, e) return "Min level", { { C.num, l }, { C.dim, (e ~= "" and ("  " .. e) or "") } } end },
  { "^%*Your (.-) must be (.-) to use this item%.?%s*(.-)$",
    function(what, cond, e) return "Requires", { { C.item, what .. " " .. cond }, { C.dim, (e ~= "" and ("  " .. e) or "") } } end },
  { "^This %a+ alters (.-)%s+with a success rate of (%d+%%)%.?$",
    function(what, pct) return "Alters", { { C.slot, what }, { C.dim, "  success " }, { C.num, pct } } end },
  { "^%*?This item may be repaired (%d+) times? and renewed (%d+) times?%.?$",
    function(r, n) return "@repairs", r, n end },
  { "^%*.- will last approximately ([%d,]+) more (.-)%.?$",
    function(n, u) return "Lasts", { { C.num, "~" .. n }, { C.text, " " .. u } } end },
  { "^This item, when USEd, will (.-)%.?$",
    function(what) return "Use", { { C.slot, what } } end },
  { "^There are (%d+) charges? remaining bound within .-%.?$",
    function(n) return "Charges", { { C.num, n } } end },
  { "^Casts the level (%d+) spell, (.-)%.?$",
    function(l, sp) return "Casts", { { C.slot, sp }, { C.dim, "  level " }, { C.num, l } } end },
  { "^Your weapon special attribute (%S+) (.-)%.?$",
    function(n, what) return "Effect", { { C.flag, n }, { C.text, " " .. what } } end },
  { "^%*This item cannot be repaired due to its (.-), but may be renewed (%d+) times?%.?$",
    function(why, n) return "Renewals", { { C.num, n }, { C.dim, "  (cannot be repaired)" } } end },
  { "^%*This item is bound to (.-)%.?$",
    function(who) return "Bound to", { { C.flag, who } } end },
  { "^There are (%d+) out of (%d+) (%a+) of (.-) in this vessel%.?$",
    function(a, b, u, what) return "Holds", { { C.num, a }, { C.dim, "/" .. b .. " " .. u .. " of " }, { C.item, what } } end },
}
function M.itemExtra(t)
  for _, e in ipairs(M.itemExtras) do
    local a, b, c, d = t:match(e[1])
    if a then
      local k, v, w = e[2](a, b, c, d)
      return { k, v, w }
    end
  end
end

function M.parseItem(raw)
  local L = {}
  for _, l in ipairs(raw) do L[#L + 1] = rtrim(l) end
  local start
  for i, l in ipairs(L) do if l:match("^Item '") then start = i break end end
  if not start then return nil end

  local it = { other = {}, affects = {}, relics = {}, desc = {}, flags = {}, extra = {}, notes = {},
               relicAffects = {}, grants = {}, bonus = {} }
  for i = 1, start - 1 do
    local n = L[i]:match("^You focus your powers of observation on (.-):%s*$")
    if n then it.focus = n elseif trim(L[i]) ~= "" then it.other[#it.other + 1] = L[i] end
  end

  -- the "Item '...' is type ..." sentence wraps over several lines; join until it ends with "."
  local hdr, i = {}, start
  repeat
    hdr[#hdr + 1] = trim(L[i]); i = i + 1
  until hdr[#hdr]:match("%.$") or i > #L or i - start >= 5
  local h = table.concat(hdr, " ")
  it.header = h
  it.name, it.type = h:match("^Item '(.-)' is type ([^,]+)")
  it.align = h:match("alignment (%-?%d+)")
  it.material, it.cond = h:match("made of (.-) %(in %((.-)%) condition%)")
  if not it.material then it.material = h:match("made of ([^,%(]+)") end
  -- flags like [Study][LTB] come after the name; names can contain brackets too ("[2026 Edition]")
  local afterName = h:match("^Item '.-' is type (.*)$") or h
  for f in afterName:gmatch("%[([^%]]+)%]") do it.flags[#it.flags + 1] = f end
  it.keywords = h:match("keywords '(.-)'")
  it.worn = h:match("equipped ([^,%.]+)")

  local lastKnown = i - 1
  local inRelics, inBonus, inContents = false, false, false
  local unknown = {}   -- {index, text}
  while i <= #L do
    local l = L[i]; local t = trim(l)
    local indented = l:match("^%s%s") ~= nil
    local slotTxt, st, pb, val, rest = t:match("^This ?(.-)item weighs (%d+) stones? and (%d+) pebbles?, and is valued at ([%d,]+) gold%.?%s*(.*)$")
    local wpnName = t:match("^Your (.-) will deal %a+ [%a%-]+ damage")
    local special = t:match("^Special weapon attributes:%s*(.-)%.?$")
    local gPct, gSkill, gDesc = t:match("^Grants knowledge at (%d+%%):%s*(.-)%s+%-%s+(.-)%.?$")
    local lvl, attrs = t:match("^This level (%d+) item has the attributes:%s*(.-)%.?$")
    local arv = t:match("^Armor resistance is (%-?%d+)%.?$")
    local rep = t:match("^%*?This item may be repaired (%d+) times?%.?$")
    local afW, afN = t:match("^Affects (.-) by (%-?%d+)%.?$")
    local x = M.itemExtra(t)
    if inContents then
      -- container contents: rows until the "A total of ..." line
      local n2, w2 = t:match("^A total of (%d+) items? weighing (.-)%.?$")
      if n2 then
        it.contentsTotal = { n2, w2 }; inContents = false
      elseif t ~= "" then
        local cnt, rest = t:match("^%(%s*(%d+)%)%s*(.+)$")
        it.contents[#it.contents + 1] = { tonumber(cnt) or 1, rest or t, idx = i }
      end
      lastKnown = i
    elseif t:match("^When you look inside, you see:?$") or t:match("^Inside you see:?$") then
      inContents = true; it.contents = it.contents or {}; lastKnown = i
    elseif t:match("^Capacity:") then
      it.capacity = t:match("^Capacity:%s*(%d+) items?")
      it.maxWeight = t:match("Maximum weight:%s*([^%.]+)")
      it.containerFlags = t:match("Flags:%s*(.-)%.?$")
      lastKnown = i
    elseif t == "" then
      inBonus = false
      unknown[#unknown + 1] = { i, "" }
    elseif t:match("^%+%+%+") then
      it.bonus[#it.bonus + 1] = { (t:gsub("^%+%+%+%s*", "")) }; inBonus = true
    elseif inBonus then
      local b = it.bonus[#it.bonus]; b[#b + 1] = t
    elseif inRelics and indented then
      it.relics[#it.relics + 1] = { text = l, idx = i }; lastKnown = i
      local rw, rn = t:match("^Affects (.-) by (%-?%d+)%.?$")
      if rw then it.relicAffects[#it.relicAffects + 1] = { rw, rn } end
    elseif wpnName then
      it.weapon = parseWeaponSummary(t); it.weapon.name = wpnName; inRelics = false; lastKnown = i
    elseif it.weapon and parseWeaponStat(t) then
      it.weapon.stats[#it.weapon.stats + 1] = parseWeaponStat(t); lastKnown = i
    elseif special then it.special = special; inRelics = false; lastKnown = i
    elseif gPct then
      it.grants[#it.grants + 1] = { gSkill, gPct, gDesc }; inRelics = false; lastKnown = i
    elseif t:match("^Relics:") then
      inRelics = true; lastKnown = i
    elseif st then
      inRelics = false
      it.weight = { st, pb }; it.value = val
      it.slots = slotTxt:match("(%d+)%-slot")
      it.cat = rest:match("{Cat%.?%s*(%w+)}")
      local left = trim(rest:gsub("{Cat%.?%s*%w+}", ""))
      if left ~= "" then unknown[#unknown + 1] = { i, left } end
      lastKnown = i
    elseif lvl then it.level, it.attrs = lvl, attrs; inRelics = false; lastKnown = i
    elseif arv then it.ar = arv; inRelics = false; lastKnown = i
    elseif rep then it.repairs = rep; inRelics = false; lastKnown = i
    elseif afW and not indented then
      it.affects[#it.affects + 1] = { afW, afN, i }; inRelics = false; lastKnown = i
    elseif x then
      if x[1] == "@level" then it.level, it.attrs = x[2], "none"
      elseif x[1] == "@repairs" then
        it.repairs = x[2]
        it.extra[#it.extra + 1] = { "Renewals", { { C.num, x[3] } } }
      else it.extra[#it.extra + 1] = x end
      inRelics = false; lastKnown = i
    elseif t:match("^%*") then
      it.notes[#it.notes + 1] = t:gsub("^%*%s*", ""); inRelics = false; lastKnown = i
    else
      inRelics = false
      unknown[#unknown + 1] = { i, l }
    end
    i = i + 1
  end
  -- unknown lines after the last recognised line are the description
  for _, u in ipairs(unknown) do
    if u[1] > lastKnown then it.desc[#it.desc + 1] = trim(u[2])
    elseif u[2] ~= "" then it.other[#it.other + 1] = u[2] end
  end
  return it
end

-- creature look / examine:
--   description, hair, race & height, posture, distance, health, then <slot> lines
local healthColor = { perfect = "plus", excellent = "plus", good = "plus", fair = "gold", poor = "minus", awful = "minus" }
function M.formatMob(raw, width)
  local desc, slots, after, facts = {}, {}, {}, {}
  local name
  local seenSlot = false
  -- equipment comes after the health / distance lines; anything slot-like before
  -- them is part of the description (descriptions can contain anything)
  local factsAt
  for i, l in ipairs(raw) do
    local t = trim(l)
    if t:match(" is in .- health%.?$") or t:match("^You are %d+ distance away from ") then factsAt = i; break end
  end
  for idx, l in ipairs(raw) do
    local t = trim(l)
    local slot, item = parseSlot(l)
    if factsAt and idx < factsAt then slot = nil end
    local hn, health = t:match("^(.-) is in (.-) health%.?$")
    local dist, dn, range = t:match("^You are (%d+) distance away from (.-) and your attack range is (%d+)%.?$")
    local race, height = t:match("^%S+ is an? (.-) approximately (.-) tall%.?$")
    local hair = t:match("^.-'s hair .-, and is:%s*(.-)%.?$")
    local pn, posture = t:match("^(.-) is (%a+)%.$")
    -- "The janitor is currently in the vagabond's formation of 2." / "-- Box Formation --" / a grid of
    -- "[janitor     ]" cells: its own section, the grid as the game draws it
    local fwho, fsize = t:match("^.- is currently in (.-) formation of (%d+)%.?$")
    local fshape = t:match("^%-%-%s*(.-)%s*%-%-$")
    local frow = t:match("^%[.-%]%s*%[.-%]") and t
    if fwho then facts.formation = { who = fwho, size = fsize }
    elseif fshape and fshape:lower():find("formation") then facts.formation = facts.formation or {}; facts.formation.shape = fshape
    elseif frow and not seenSlot then facts.grid = facts.grid or {}; facts.grid[#facts.grid + 1] = t
    elseif slot then slots[#slots + 1] = { slot, item, runs = M.runsFor(idx, (stripConds(item))) }; seenSlot = true
    elseif seenSlot then if t ~= "" then after[#after + 1] = t end
    elseif hn then name = name or hn
      local word = health:lower():match("(%a+)%s*$") or ""
      local col = healthColor[word] == "plus" and C.plus or (healthColor[word] == "minus" and C.minus or "gold")
      facts.health = { { col, health } }
    elseif dist then name = dn
      facts.distance = { { C.num, dist }, { C.dim, "  (your attack range " .. range .. ")" } }
    elseif race then facts.race = { { C.item, race }, { C.dim, ", " .. height } }
    elseif hair then facts.hair = { { C.item, hair } }
    elseif pn and #t < 40 then facts.posture = { { C.item, posture } }
    else desc[#desc + 1] = t end
  end
  if #slots == 0 and not facts.health and not facts.distance then return nil end
  local out = {}
  local cells = {}
  if facts.health then cells[#cells + 1] = { "Health", facts.health } end
  if facts.posture then cells[#cells + 1] = { "Status", facts.posture } end
  if facts.distance then cells[#cells + 1] = { "Distance", facts.distance } end
  grid(out, cells, width)
  if facts.race then kvLine(out, "Race", 8, facts.race, width) end
  if facts.hair then kvLine(out, "Hair", 8, facts.hair, width) end
  paragraphs(out, desc, width)
  if facts.formation or facts.grid then
    subhead(out, "Formation")
    local f = facts.formation or {}
    local segs = {}
    if f.who then segs[#segs + 1] = { C.item, f.who }; segs[#segs + 1] = { C.dim, " formation of " }; segs[#segs + 1] = { C.num, f.size } end
    if f.shape then segs[#segs + 1] = { C.dim, (#segs > 0 and "  ·  " or "") .. f.shape } end
    if #segs > 0 then out[#out + 1] = segs end
    local me = name and name:lower():gsub("^the ", ""):gsub("^an? ", "")
    for _, row in ipairs(facts.grid or {}) do
      local r = {}
      for cell in row:gmatch("%[[^%]]*%]") do
        local inner = trim(cell:sub(2, -2))
        local col = inner:match("^%-+$") and C.dim or ((me and inner:lower() == me) and C.title or C.item)
        r[#r + 1] = { col, cell }; r[#r + 1] = { C.text, "  " }
      end
      out[#out + 1] = r
    end
  end
  if #slots > 0 then
    subhead(out, "Equipment")
    renderSlots(out, slots, width)
  end
  if #after > 0 then blank(out); for _, o in ipairs(after) do prose(out, { o }, width) end end
  return out, name
end

function M.formatters.item(raw, width)
  local it = M.parseItem(raw)
  if not it or not it.name then
    local out, title = M.formatMob(raw, width)
    if out then return out, title end
    return M.formatters.generic(raw, width)
  end
  local out = {}
  local cells = {}
  local function add(k, segs) if segs then cells[#cells + 1] = { k, segs } end end
  add("Type", it.type and { { C.item, it.type } })
  add("Level", it.level and { { C.num, it.level } })
  add("Material", it.material and { { C.item, it.material } })
  add("Condition", it.cond and condSegs({ it.cond }))
  if cells[#cells] and cells[#cells][1] == "Condition" then cells[#cells][2][1][2] = it.cond end
  add("Worn", it.worn and { { C.item, it.worn } })
  add("Align", it.align and numSegs(it.align))
  add("Weight", it.weight and { { C.num, it.weight[1] }, { C.text, " st " }, { C.num, it.weight[2] }, { C.text, " pb" } })
  add("Value", it.value and { { C.num, it.value }, { C.text, " gold" } })
  if it.ar then
    local segs = numSegs(it.ar)
    local rate = M.cfg.arRate
    if rate and tonumber(it.ar) then
      local loc = M.arLocationFor(it.worn)
      segs[#segs + 1] = { C.dim, string.format("  %%-%.2f dmg%s", tonumber(it.ar) * rate, loc and (" " .. loc) or "") }
    end
    add("Armor", segs)
  end
  add("Repairs", it.repairs and { { C.num, it.repairs }, { C.text, " left" } })
  add("Category", it.cat and { { C.num, it.cat } })
  add("Slots", it.slots and { { C.num, it.slots } })
  add("Capacity", it.capacity and { { C.num, it.capacity }, { C.text, " items" } })
  add("Max weight", it.maxWeight and { { C.num, it.maxWeight } })
  add("Container", it.containerFlags and it.containerFlags ~= "" and { { C.item, it.containerFlags } } or nil)
  grid(out, cells, width)

  local kw = 9
  if it.keywords then kvLine(out, "Keywords", kw, { { C.slot, it.keywords } }, width) end
  if #it.flags > 0 then kvLine(out, "Flags", kw, { { C.flag, table.concat(it.flags, " · ") } }, width) end
  if it.attrs and it.attrs ~= "" then
    kvLine(out, "Attribs", kw, { { it.attrs == "none" and C.dim or C.flag, it.attrs } }, width)
  end
  if #it.affects > 0 then
    local segs = {}
    for n, a in ipairs(it.affects) do
      if n > 1 then segs[#segs + 1] = { C.dim, ", " } end
      for _, s in ipairs(affectSegs(a[1], a[2], a[3] and M.colorAt(a[3], "Affects"))) do segs[#segs + 1] = s end
    end
    kvLine(out, "Affects", kw, segs, width)
  end
  if #it.relics > 0 then
    local first = true
    for _, rel in ipairs(it.relics) do
      local r = type(rel) == "table" and rel.text or rel
      local depth = #(r:match("^(%s*)")) - 2
      local ridx = type(rel) == "table" and rel.idx or nil
      local t = trim(r):gsub("%s+", " ")
      local segs
      local afW, afN = t:match("^Affects (.-) by (%-?%d+)%.?$")
      if afW then
        segs = affectSegs(afW, afN, M.colorAt(ridx, "Affects"))
      else
        local name, van = t:match("^(.-)%s*%[Vanishes (.-)%]$")
        if name then
          segs = itemSegs(name)
          local rawVan = trim(r):match("%[Vanishes (.-)%]$") or van
          segs[#segs + 1] = { M.colorAt(ridx, "[Vanishes") or C.dim, "  vanishes " }
          segs[#segs + 1] = { M.colorAt(ridx, rawVan) or C.dim, van }
        else
          -- lines Oven doesn't rearrange ("Small (1/1):", "When wielding ...") keep the game's colours
          segs = M.runsExact(ridx, trim(r)) or { { C.item, t } }
        end
      end
      table.insert(segs, 1, { C.text, string.rep(" ", math.max(0, depth)) })
      kvLine(out, first and "Relics" or "", kw, segs, width)
      first = false
    end
  end
  for _, x in ipairs(it.extra) do kvLine(out, x[1], kw, x[2], width) end
  if it.special then kvLine(out, "Special", kw, { { C.flag, it.special } }, width) end
  for n, g in ipairs(it.grants) do
    kvLine(out, n == 1 and "Grants" or "", kw,
      { { C.slot, g[1] }, { C.num, " " .. g[2] }, { C.dim, "  " .. g[3] } }, width)
  end
  if it.contents then
    subhead(out, "Contents")
    if #it.contents == 0 then out[#out + 1] = { { C.dim, "     (empty)" } } end
    for _, r in ipairs(it.contents) do
      local row = { { C.num, r[1] > 1 and string.format("%3d× ", r[1]) or "     " } }
      local segs = itemSegs(r[2], M.runsFor(r.idx, (stripConds(r[2]))))
      if 5 + segLen(segs) <= width then
        addAll(row, segs); out[#out + 1] = row
      else
        addAll(out, wrapWords(r[2], width, 5, C.item, row, 5))
      end
    end
    if it.contentsTotal then
      local function wt(x) return (x:gsub(" stones?", " st"):gsub(" sts", " st"):gsub(" pebbles?", " pb"):gsub(" pbs", " pb")) end
      local row = { { C.key, "Items " }, { C.num, it.contentsTotal[1] } }
      if it.capacity then row[#row + 1] = { C.dim, "/" .. it.capacity } end
      row[#row + 1] = { C.key, "    Weight " }; row[#row + 1] = { C.num, wt(it.contentsTotal[2]) }
      if it.maxWeight then row[#row + 1] = { C.dim, " / " .. wt(it.maxWeight) } end
      blank(out); out[#out + 1] = row
    end
  end
  if it.weapon then
    subhead(out, "Weapon")
    renderWeapon(out, it.weapon, width)
    blank(out)
  end
  for n, note in ipairs(it.notes) do
    kvLine(out, n == 1 and "Notes" or "", kw, { { C.text, note } }, width)
  end
  if #it.other > 0 then
    blank(out)
    for _, o in ipairs(it.other) do prose(out, { o }, width) end
  end
  paragraphs(out, it.desc, width)
  for _, b in ipairs(it.bonus) do
    blank(out)
    local text = table.concat(b, " "):gsub("%s+", " ")
    addAll(out, wrapWords(trim(text), width, 4, C.text, { { C.flag, "+++ " } }, 4))
  end
  return out, it.name
end

---------------------------------------------------------------- containers / inventory
function M.formatters.contents(raw, width)
  local title, rows, footer, other = nil, {}, nil, {}
  for idx, l in ipairs(raw) do
    local t = trim(l)
    local n, items, w, maxW = t:match("^A total of (%d+) %((%d+) max%) items weighing (.-) %((.-) max%)%.?$")
    local invN, invW, invGold = t:match("^A total of (%d+) items weighing (.-)%s*%((.-) gold weight%)%.?$")
    if not invN then invN, invW = t:match("^A total of (%d+) items weighing (.-)%.?$") end
    local capN, capW = t:match("^You may carry a maximum of (%d+) items weighing up to (.-)%.?$")
    if t == "" or t == "Search inventory" then
    elseif invN then
      footer = footer or {}
      footer[1], footer[3], footer.gold = invN, invW, invGold
    elseif capN then
      footer = footer or {}
      footer[2], footer[4] = capN, capW
    elseif not title and #rows == 0 and t:match(":$") then
      title = t:gsub(":$", ""):gsub("%s+contains$", "")
    elseif n then
      footer = { n, items, w, maxW }
    else
      local cnt, rest = t:match("^%(%s*(%d+)%)%s*(.+)$")
      local txt = rest or t
      rows[#rows + 1] = { tonumber(cnt) or 1, txt, runs = M.runsFor(idx, (stripConds(txt))) }
    end
  end
  if #rows == 0 then return M.formatters.generic(raw, width) end
  local out = {}
  for _, r in ipairs(rows) do
    local row = { { C.num, r[1] > 1 and string.format("%3d× ", r[1]) or "     " } }
    local segs = itemSegs(r[2], r.runs)
    if 5 + segLen(segs) <= width then
      for _, s in ipairs(segs) do row[#row + 1] = s end
      out[#out + 1] = row
    else
      addAll(out, wrapWords(r[2], width, 5, C.item, row, 5))
    end
  end
  if footer then
    blank(out)
    local function wt(s)
      return (s:gsub(" stones?", " st"):gsub(" sts", " st"):gsub(" pebbles?", " pb"):gsub(" pbs", " pb"))
    end
    local row = { { C.key, "Items " }, { C.num, footer[1] or "?" } }
    if footer[2] then row[#row + 1] = { C.dim, "/" .. footer[2] } end
    if footer[3] then
      row[#row + 1] = { C.key, "    Weight " }; row[#row + 1] = { C.num, wt(footer[3]) }
      if footer[4] then row[#row + 1] = { C.dim, " / " .. wt(footer[4]) } end
    end
    if footer.gold then row[#row + 1] = { C.dim, "  (gold " .. footer.gold .. ")" } end
    out[#out + 1] = row
  end
  return out, title and ((title:gsub("^%l", string.upper)))
end

---------------------------------------------------------------- score
-- text gauge: ███████░░░
local function gauge(cur, max, n, col)
  cur, max = tonumber(cur) or 0, tonumber(max) or 0
  local k = max > 0 and math.floor(n * math.min(cur, max) / max + 0.5) or 0
  local pct = max > 0 and cur / max or 0
  col = col or (pct >= 0.66 and C.plus or pct >= 0.33 and "gold" or C.minus)
  return { { col, string.rep("█", k) }, { C.dim, string.rep("░", n - k) } }
end
M.gauge = gauge

M.maxNames = { ["Hit Points"] = "hp", ["Spell Points"] = "sp", ["Stamina"] = "st" }
local function commaNum(n)
  n = tonumber((tostring(n):gsub(",", "")))
  if not n then return "?" end
  local int = tostring(math.floor(math.abs(n))):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
  return (n < 0 and "-" or "") .. int
end
M.commaNum = commaNum

-- pull everything out of `score` into one table
function M.parseScore(raw)
  local sc = { info = {}, pools = {}, attrs = {}, ratings = {}, other = {} }
  for _, l in ipairs(raw) do
    local t = trim(l)
    local who = t:match("^Player Information for:%s*(.+)$")
    if t == "" then
    elseif who then sc.title = who
    elseif t:match("^%*%s*%u%u%u:") then
      for k, v in t:gmatch("(%u%u%u):%s*(%-?%d+)") do sc.ratings[#sc.ratings + 1] = { k, v } end
    elseif t:match("^%*%s*Class Path:") then
      sc.path = {}
      for n, c in t:gmatch("(%d%a%a):%s*(%S+)") do if c ~= "(n/a)" then sc.path[#sc.path + 1] = c end end
    elseif t:match("^%*") then
      local s2 = trim(t:gsub("^%*%s*", ""))
      local e, need = s2:match("^You have ([%d,]+) experience points and need ([%d,]+) to advance")
      local mk, md = s2:match("^You have killed ([%d,]+) and been killed by ([%d,]+) creatures")
      local pk, pd = s2:match("^You have killed ([%d,]+) and been killed by ([%d,]+) players")
      local hoard = s2:match("^If CPKed, your hoard would be valued at ([%d,]+) gp")
      local ci, cw = s2:match("^You are carrying (%d+) items weighing (.-)%.?$")
      local marks, rel = s2:match("^You have attained (%d+) marks and (%d+) relationships")
      if e then sc.exp, sc.tnl = e, need
      elseif mk then sc.mobKills, sc.mobDeaths = mk, md
      elseif pk then sc.pkKills, sc.pkDeaths = pk, pd
      elseif hoard then sc.hoard = hoard
      elseif ci then sc.carry = { ci, cw }
      elseif marks then sc.marks, sc.rel = marks, rel
      else sc.other[#sc.other + 1] = s2 end
    else
      local k1, v1, k2, v2 = t:match("^([%a][%a ]-):%s+(.-)%s%s+([%a][%a ]-):%s+(.-)$")
      if not k1 then k1, v1 = t:match("^([%a][%a ]-):%s+(.-)$") end
      if not k1 then sc.other[#sc.other + 1] = t
      else
        for _, kv in ipairs({ { k1, v1 }, { k2, v2 } }) do
          if kv[1] then
            local k, v = trim(kv[1]), trim(kv[2])
            local cur, max = v:match("^(%-?%d+)/(%d+)$")
            if M.maxNames[k] and cur then sc.pools[#sc.pools + 1] = { k, cur, max }
            elseif cur then sc.attrs[#sc.attrs + 1] = { k, cur, max }
            else sc.info[k] = v end
          end
        end
      end
    end
  end
  return sc
end

local poolLabel = { ["Hit Points"] = "HP", ["Spell Points"] = "SP", ["Stamina"] = "ST" }
local poolColor = { ["Hit Points"] = "tomato", ["Spell Points"] = "light_sky_blue", ["Stamina"] = "gold" }

function M.formatters.score(raw, width)
  local sc = M.parseScore(raw)
  local I = sc.info
  if not (I["Class Level"] or #sc.pools > 0) then return M.formatters.generic(raw, width) end
  local out = {}

  -- headline: what matters while playing
  local lvl = I["Class Level"]
  local head = { { C.title, "Level " }, { C.num, lvl or "?" } }
  if I["Class"] then head[#head + 1] = { C.item, " " .. I["Class"] } end
  if I["Race"] then head[#head + 1] = { C.dim, " · " }; head[#head + 1] = { C.item, I["Race"] } end
  if I["Total Level"] and I["Total Level"] ~= lvl then
    head[#head + 1] = { C.dim, "   total level " }; head[#head + 1] = { C.num, I["Total Level"] }
  end
  out[#out + 1] = head
  if sc.tnl then
    local nxt = tonumber(lvl or "") and (" to level " .. (tonumber(lvl) + 1)) or " to next level"
    out[#out + 1] = { { C.plus, commaNum(sc.tnl) }, { C.text, " exp" .. nxt },
                      { C.dim, "   (" .. commaNum(sc.exp) .. " total)" } }
    local T = M.cfg.levelTable
    local L = tonumber(I["Class Level"] or "")
    if type(T) == "table" and L and T[L] and T[L + 1] then
      local expN = tonumber((sc.exp:gsub(",", "")))
      local frac = math.max(0, math.min(1, (expN - T[L]) / (T[L + 1] - T[L])))
      local row = {}
      addAll(row, gauge(frac * 100, 100, 20, C.plus))
      row[#row + 1] = { C.num, string.format("  %d%%", math.floor(frac * 100)) }
      row[#row + 1] = { C.dim, " of the way to " .. (L + 1) }
      out[#out + 1] = row
    end
    local rate = M.expRate and M.expRate()
    if rate and rate > 0 then
      local tnlN = tonumber((sc.tnl:gsub(",", "")))
      out[#out + 1] = { { C.dim, string.format("at %s exp/hour this session: level in ≈ ", commaNum(math.floor(rate))) },
                        { C.title, M.duration(tnlN * 3600 / rate) } }
    end
  end
  if sc.path and #sc.path > 1 then
    out[#out + 1] = { { C.dim, "Class path: " }, { C.item, table.concat(sc.path, " → ") } }
  end

  if #sc.pools > 0 then
    blank(out)
    local gw = math.max(10, math.min(30, width - 20))
    for _, v in ipairs(sc.pools) do
      local row = { { poolColor[v[1]] or C.key, pad(poolLabel[v[1]] or v[1], 4) },
                    { C.num, string.format("%9s ", v[2] .. "/" .. v[3]) } }
      addAll(row, gauge(v[2], v[3], gw))
      out[#out + 1] = row
    end
  end

  if #sc.attrs > 0 then
    subhead(out, "Attributes  (current/max)")
    local cells = {}
    for _, a in ipairs(sc.attrs) do
      local segs = { { C.num, string.format("%5s ", a[2] .. "/" .. a[3]) } }
      addAll(segs, gauge(a[2], a[3], 8, C.slot))
      cells[#cells + 1] = { a[1], segs }
    end
    grid(out, cells, width)
  end

  if #sc.ratings > 0 then
    subhead(out, "Ratings")
    local row = {}
    for n, r in ipairs(sc.ratings) do
      row[#row + 1] = { C.key, r[1] .. " " }; row[#row + 1] = { C.num, string.format("%3s", r[2]) }
      if n % 3 == 0 or n == #sc.ratings then out[#out + 1] = row; row = {} else row[#row + 1] = { C.dim, "    " } end
    end
  end

  -- spendables and standing
  local cells = {}
  if I["Practices"] then cells[#cells + 1] = { "Practices", { { C.num, I["Practices"] } } } end
  if I["Quest Points"] then
    local qp, qn = I["Quest Points"]:match("^(%d+)%s*%((%d+) quests?%)")
    cells[#cells + 1] = { "Quest points", qp and { { C.num, qp }, { C.dim, "  " .. qn .. " quests done" } }
                                              or { { C.num, I["Quest Points"] } } }
  end
  if I["Alignment"] then
    local n, word = I["Alignment"]:match("^(%-?%d+)%s*%(%+?(.-)%)")
    cells[#cells + 1] = { "Alignment", n and { { C.num, n }, { C.dim, "  " .. word } } or { { C.item, I["Alignment"] } } }
  end
  if I["Reputation"] then
    local n, word = I["Reputation"]:match("^(%-?%d+)%s*%((.-)%)")
    cells[#cells + 1] = { "Reputation", n and { { C.num, n }, { C.dim, "  " .. word } } or { { C.item, I["Reputation"] } } }
  end
  if #cells > 0 then subhead(out, "Standing"); grid(out, cells, width) end

  -- kill record, spelled out
  if sc.mobKills or sc.pkKills or sc.marks then
    subhead(out, "Record")
    local function kd(label, k, d)
      out[#out + 1] = { { C.key, pad(label, 12) }, { C.text, "you killed " }, { C.plus, pad(k, 5) },
                        { C.text, "killed you " }, { C.minus, d } }
    end
    if sc.mobKills then kd("Creatures", sc.mobKills, sc.mobDeaths) end
    if sc.pkKills then kd("Players", sc.pkKills, sc.pkDeaths) end
    if sc.marks then
      out[#out + 1] = { { C.key, pad("Marks", 12) }, { C.num, pad(sc.marks, 16) },
                        { C.key, "Relationships " }, { C.num, sc.rel } }
    end
  end

  -- trivia, dimmed
  local misc = {}
  if I["Hours Played"] then misc[#misc + 1] = I["Hours Played"] .. " hours played" end
  if I["Age"] then misc[#misc + 1] = "age " .. I["Age"]:gsub("%s*%[.-%]", "") end
  if I["Gender"] then misc[#misc + 1] = I["Gender"] end
  if sc.hoard then misc[#misc + 1] = "CPK hoard " .. sc.hoard .. " gp" end
  if sc.carry then misc[#misc + 1] = "carrying " .. sc.carry[1] .. " items (" .. sc.carry[2]:gsub(" stones", " st"):gsub(" pebbles", " pb") .. ")" end
  for k, v in pairs(I) do
    local known = { ["Class Level"] = 1, ["Total Level"] = 1, Race = 1, Class = 1, Practices = 1, ["Quest Points"] = 1,
                    Alignment = 1, Reputation = 1, ["Hours Played"] = 1, Age = 1, Gender = 1 }
    if not known[k] then misc[#misc + 1] = k:lower() .. " " .. v end
  end
  for _, o in ipairs(sc.other) do misc[#misc + 1] = o end
  if #misc > 0 then
    blank(out)
    addAll(out, wrapWords(table.concat(misc, "  ·  "), width, 0, C.dim))
  end
  return out, sc.title
end

---------------------------------------------------------------- levels
-- exp needed for each level, from the game's `level` command (saved once seen)
function M.levelInfo()
  local T, c = M.cfg.levelTable, M.cfg.char or {}
  if type(T) ~= "table" or not c.level then return nil end
  local lvl = c.level
  local cur, nxt = T[lvl] or T[tostring(lvl)], T[lvl + 1] or T[tostring(lvl + 1)]
  if not cur or not nxt or nxt <= cur then return nil end
  local exp = c.exp or (c.tnl and (nxt - c.tnl))
  if not exp then return nil end
  local frac = math.max(0, math.min(1, (exp - cur) / (nxt - cur)))
  return { level = lvl, exp = exp, cur = cur, nxt = nxt, frac = frac }
end

function M.formatters.levels(raw, width)
  local T = {}
  for _, l in ipairs(raw) do
    local n, x = l:match("%[Level:%s*(%d+)%]%s*Experience Required:%s*([%d,]+)")
    if n then T[tonumber(n)] = tonumber((x:gsub(",", ""))) end
  end
  if not next(T) then return M.formatters.generic(raw, width) end
  M.cfg.levelTable = T
  M.saveSettings()
  local maxL = 0
  for n in pairs(T) do maxL = math.max(maxL, n) end
  local c = M.cfg.char or {}
  local exp = c.exp
  local rate = M.expRate and M.expRate()
  local out = {}
  local info = M.levelInfo()
  if info then
    local row = { { C.title, "You: " }, { C.text, "level " }, { C.num, tostring(info.level) }, { C.dim, "  " } }
    addAll(row, M.gauge(info.frac * 100, 100, 20, C.plus))
    row[#row + 1] = { C.num, string.format("  %d%%", math.floor(info.frac * 100)) }
    row[#row + 1] = { C.dim, " of the way to " .. (info.level + 1) }
    out[#out + 1] = row
    blank(out)
  end
  local first = 1
  if c.level then
    out[#out + 1] = { { C.dim, string.format("levels 1-%d reached", c.level) } }
    first = c.level + 1
  end
  out[#out + 1] = { { C.key, string.format("%-6s %12s %10s %12s   %s", "level", "exp needed", "step", "to go", rate and "at this pace" or "") } }
  for L = first, maxL do
    local need = T[L]
    if need then
      local step = T[L - 1] and (need - T[L - 1]) or need
      local toGo = exp and math.max(0, need - exp)
      local eta = (toGo and rate and rate > 0) and ("≈ " .. M.duration(toGo * 3600 / rate)) or ""
      out[#out + 1] = {
        { L == first and C.title or C.text, string.format("%-6d ", L) },
        { C.num, string.format("%12s ", M.commaNum(need)) },
        { C.dim, string.format("%10s ", "+" .. M.commaNum(step)) },
        { L == first and C.plus or C.text, string.format("%12s   ", toGo and M.commaNum(toGo) or "") },
        { C.dim, eta },
      }
    end
  end
  return out, "Levels"
end

---------------------------------------------------------------- skills / practice
-- remembered from `skills spells` / `skills prof`: name (lower) -> { lrnd, cmplx, rec, group }
local function skillKey(n) return trim(n):lower() end

-- `skills spells` / `skills prof` table
function M.parseSkillTable(raw)
  local rows, kind, footer = {}, nil, {}
  for idx, l in ipairs(raw) do
    local t = trim(l)
    if t:match("^%[ # %] %[%s*Spell Name") then kind = "spells"
    elseif t:match("^%[ # %] %[%s*Proficiency Name") then kind = "proficiencies"
    else
      local n, name, grp, rest = t:match("^(%d+)%s+(.-)%s%s+(%u%u%u)%s+(.*)$")
      if n then
        local sp, cm, lr, star
        if kind == "spells" then sp, cm, lr, star = rest:match("^(%d+)%s+(%d+)%%%s+(%d+)%%%s*(.*)$")
        else cm, lr, star = rest:match("^(%d+)%%%s+(%d+)%%%s*(.*)$") end
        if lr then
          rows[#rows + 1] = { name = name, group = grp, sp = sp, cmplx = tonumber(cm), lrnd = tonumber(lr),
                              rec = star and star:find("%*") ~= nil, idx = idx }
        end
      elseif t:match("^You have the ability to learn") then footer.can = t; footer.canIdx = idx
      elseif t:match("^You have %[%d+%] practice") then footer.prac = t:match("%[(%d+)%]")
      elseif t ~= "" then footer.other = footer.other or {}; footer.other[#footer.other + 1] = { t, idx } end
    end
  end
  return kind and #rows > 0 and { kind = kind, rows = rows, footer = footer } or nil
end

-- `practice` at a trainer: "Name   [ 1%] No limit  Name2   [15%] No limit"
function M.parsePractice(raw)
  local trainer, list, prac
  local other = {}
  for idx, l in ipairs(raw) do
    local t = trim(l)
    local who = t:match("^(.-) can train you in the following skills") or t:match("^(.-) offers training in the following skills")
    if who then trainer = who; list = {}
    elseif list and t:find("%[%s*%d+%%%]") then
      -- split around each "[ nn%]"
      local pos, name = 1, nil
      local s = l
      while true do
        local a, b, pct = s:find("%[%s*(%d+)%%%]", pos)
        if not a then break end
        local before = s:sub(pos, a - 1)
        if not name then name = trim(before)
        else
          -- before = "<avail of previous>  <next name>"
          local avail, nextName = before:match("^%s*(.-)%s%s+(%S.-)%s*$")
          if list[#list] then list[#list].avail = trim(avail or before) end
          name = trim(nextName or before)
        end
        list[#list + 1] = { name = name, lrnd = tonumber(pct), idx = idx }
        pos = b + 1
      end
      if list[#list] then list[#list].avail = trim(s:sub(pos)) end
    elseif t:match("^You have %[%d+%] practice") then prac = t:match("%[(%d+)%]")
    elseif t ~= "" and not t:match("^Skill Name%s+Lrnd") then other[#other + 1] = l end
  end
  return trainer and { trainer = trainer, list = list or {}, prac = prac, other = other } or nil
end

-- recommended skills: turquoise name and star. A name the game coloured differently from the
-- rest keeps the game's colour (it signals a status: inactive, altered…) and just gets the star.
local REC = { 64, 224, 208 }
M.REC = REC
local function usualColour(rows)
  local count, best, bestN = {}, nil, 0
  for _, r in ipairs(rows) do
    local segs = M.runsExact(r.idx, r.name)
    local c = segs and type(segs[1][1]) == "table" and table.concat(segs[1][1], ",") or "plain"
    count[c] = (count[c] or 0) + 1
    if count[c] > bestN then best, bestN = c, count[c] end
  end
  return best
end
local function nameSegs(r, rec, usual)
  local segs = M.runsExact(r.idx, r.name)
  if rec then
    local c = segs and type(segs[1][1]) == "table" and table.concat(segs[1][1], ",") or "plain"
    if c == usual then return { { REC, r.name } } end
  end
  return segs or { { C.item, r.name } }
end
local function starSeg(rec) return rec and { REC, "★ " } or { C.text, "  " } end

local function learnedSegs(pct, width)
  local segs = {}
  addAll(segs, M.gauge(pct, 100, width))
  segs[#segs + 1] = { C.num, string.format(" %3d%%", pct) }
  return segs
end

-- `train`: "strength   8/20   80"
function M.parseTrain(raw)
  local rows, prac, started = {}, nil, false
  for idx, l in ipairs(raw) do
    local t = trim(l)
    local p = t:match("^You have (%d+) practice sessions?")
    if p then prac = tonumber(p) end
    if t:match("^Attribute Name") then started = true
    elseif started then
      local name, cur, mx, cost = t:match("^(%a[%a ]-)%s+(%d+)/(%d+)%s+(%d+)$")
      if name then rows[#rows + 1] = { name = name, cur = tonumber(cur), max = tonumber(mx), cost = tonumber(cost) } end
    end
  end
  return #rows > 0 and { rows = rows, prac = prac } or nil
end

function M.formatters.skills(raw, width)
  local tr = M.parseTrain(raw)
  if tr then
    local out, prac = {}, tr.prac or 0
    local nameW = 0
    for _, r in ipairs(tr.rows) do nameW = math.max(nameW, ulen(r.name)) end
    local gw = width >= 80 and 10 or 6
    out[#out + 1] = { { C.key, pad("", nameW) .. "     current" .. string.rep(" ", gw + 1) .. "   cost" } }
    local vitals = { hp = true, sp = true, st = true }
    for i, r in ipairs(tr.rows) do
      if vitals[r.name] and i > 1 and not vitals[tr.rows[i - 1].name] then blank(out) end
      local full = r.cur >= r.max
      local afford = (not full and r.cost > 0) and math.floor(prac / r.cost) or 0
      local row = { { full and C.dim or C.item, pad(r.name, nameW) } }
      row[#row + 1] = { C.num, string.format("%12s ", r.cur .. "/" .. r.max) }
      addAll(row, M.gauge(r.cur, r.max, gw, vitals[r.name] and C.slot or nil))
      row[#row + 1] = { afford > 0 and C.plus or C.dim, string.format("%7d", r.cost) }
      if full then row[#row + 1] = { C.dim, "   maxed" }
      elseif afford > 0 then row[#row + 1] = { C.plus, "   ×" .. afford }
      end
      out[#out + 1] = row
    end
    blank(out)
    out[#out + 1] = { { C.dim, "cost in practices  ·  ×N = how many times you can train it with " }, { C.num, tostring(prac) },
                      { C.dim, " practices" } }
    return out, "Train  (" .. prac .. " practices)"
  end

  local tbl = M.parseSkillTable(raw)
  if tbl then
    -- remember them for the practice planner
    M.cfg.skills = M.cfg.skills or {}
    for _, r in ipairs(tbl.rows) do
      M.cfg.skills[skillKey(r.name)] = { lrnd = r.lrnd, cmplx = r.cmplx, rec = r.rec, group = r.group }
    end
    M.saveSettings()
    local out = {}
    local first = tbl.kind == "spells" and "Spell" or "Proficiency"
    local nameW = ulen(first)
    for _, r in ipairs(tbl.rows) do nameW = math.max(nameW, ulen(r.name)) end
    local gw = width >= 80 and 10 or 6
    out[#out + 1] = { { C.key, "  " .. pad(first, nameW + 2)
      .. pad(tbl.kind == "spells" and "School" or "Type", 8)
      .. (tbl.kind == "spells" and string.format("%7s", "SP cost") or "")
      .. string.format("%12s", "Complexity") .. "  Learned" } }
    local usual = usualColour(tbl.rows)
    for _, r in ipairs(tbl.rows) do
      local row = { starSeg(r.rec) }
      addAll(row, nameSegs(r, r.rec, usual))
      row[#row + 1] = { C.text, string.rep(" ", nameW + 2 - ulen(r.name)) }
      row[#row + 1] = { C.slot, pad(r.group, 8) }
      if r.sp then row[#row + 1] = { C.num, string.format("%7s", r.sp) } end
      row[#row + 1] = { C.dim, string.format("%11d%%  ", r.cmplx) }
      addAll(row, learnedSegs(r.lrnd, gw))
      out[#out + 1] = row
    end
    blank(out)
    -- the game's own footer lines (colour key etc.), in its colours
    for _, o in ipairs(tbl.footer.other or {}) do
      out[#out + 1] = M.runsExact(o[2], o[1]) or { { C.dim, o[1] } }
    end
    if tbl.footer.can then out[#out + 1] = M.runsExact(tbl.footer.canIdx, tbl.footer.can) or { { C.text, tbl.footer.can } } end
    local f = { { REC, "★ recommended for your class" } }
    if tbl.footer.prac then f[#f + 1] = { C.dim, "  ·  practices: " }; f[#f + 1] = { C.num, tbl.footer.prac } end
    out[#out + 1] = f
    return out, (tbl.kind == "spells" and "Spells" or "Proficiencies") .. " (" .. #tbl.rows .. ")"
  end

  local pr = M.parsePractice(raw)
  if pr then
    -- every skill the trainer lists, one row each, sorted by how far along you are
    local out, mine = {}, M.cfg.skills or {}
    local list, rec = {}, {}
    for _, s2 in ipairs(pr.list) do
      list[#list + 1] = s2
      local info = mine[skillKey(s2.name)]
      if info and info.rec then rec[#rec + 1] = s2 end
    end
    table.sort(list, function(x, y)
      if x.lrnd ~= y.lrnd then return x.lrnd > y.lrnd end
      return x.name:lower() < y.name:lower()
    end)
    -- availability: the most common value is stated once; rows only show it where it differs
    local countA, commonA, commonN = {}, nil, 0
    for _, s2 in ipairs(list) do
      local a = s2.avail or ""
      countA[a] = (countA[a] or 0) + 1
      if countA[a] > commonN then commonA, commonN = a, countA[a] end
    end
    local allSame = commonN == #list
    local usual = usualColour(list)
    if #rec > 0 then
      local row = { { REC, "★ recommended, trainable here: " } }
      for i, s2 in ipairs(rec) do
        if i > 1 then row[#row + 1] = { C.dim, ", " } end
        row[#row + 1] = { REC, s2.name }; row[#row + 1] = { C.num, " " .. s2.lrnd .. "%" }
      end
      out[#out + 1] = row
      blank(out)
    end
    local hdr = { { C.title, #list .. " skills" } }
    out[#out + 1] = hdr
    local nameW = 0
    for _, s2 in ipairs(list) do nameW = math.max(nameW, ulen("Skill"), ulen(s2.name)) end
    local gw = width >= 80 and 10 or 6
    out[#out + 1] = { { C.key, "  " .. pad("Skill", nameW + 1) .. pad("Learned", gw + 5) .. "   Availability" } }
    for _, s2 in ipairs(list) do
      local info = mine[skillKey(s2.name)]
      local isRec = info and info.rec
      local r = { starSeg(isRec) }
      addAll(r, nameSegs(s2, isRec, usual))
      r[#r + 1] = { C.text, string.rep(" ", nameW + 1 - ulen(s2.name)) }
      addAll(r, learnedSegs(s2.lrnd, gw))
      -- availability on every row: ∞ for "No limit", the game's value otherwise
      local av = s2.avail or ""
      if av:lower() == "no limit" then r[#r + 1] = { C.dim, "   ∞" }
      elseif av ~= "" then r[#r + 1] = { C.flag, "   " .. av } end
      out[#out + 1] = r
    end
    if pr.prac then blank(out); out[#out + 1] = { { C.key, "Practices available: " }, { C.num, pr.prac } } end
    if #pr.other > 0 then
      blank(out)
      for _, o in ipairs(pr.other) do addAll(out, wrapWords(trim(o), width, 7, C.dim)) end
    end
    return out, pr.trainer .. " can train you"
  end
  return M.formatters.generic(raw, width)
end

---------------------------------------------------------------- quests
-- remembered quests: id -> { name, done, total, phases = {{n, text, area, done}}, levels, master, rewards, limit }
M.quests = M.quests or {}

-- "*Defeat 5/5 of a lost demon [Rune Forest] [Group]." -> text, area, tags, done (a leading * means done).
-- The area is the last [bracket] (after tags like [Group]); brackets earlier in the step belong to its text:
-- "Locate and deliver sprutter spritz [Cooking Adventurers] to a bag lady [Towne of Rune]."
local PHASE_TAGS = { group = true }
function M.phaseFromText(ptext)
  local isDone = ptext:sub(1, 1) == "*"
  local text = trim(ptext:gsub("^%*", ""):gsub("%.$", ""))
  local area, tags = nil, nil
  while true do
    local before, last = text:match("^(.-)%s*%[([^%[%]]+)%]$")
    if not before then break end
    if PHASE_TAGS[last:lower()] then
      tags = tags or {}
      table.insert(tags, 1, last)
      text = before
    else
      area, text = last, before
      break
    end
  end
  return { text = text, area = area, tags = tags, done = isDone }
end

-- steps saved by 0.52.0 and older with two brackets read as one area ("Rune Forest] [Group"): read again
function M.fixQuestPhases()
  for _, Q in pairs(M.quests or {}) do
    for _, ph in ipairs(Q.phases or {}) do
      if ph.area and ph.area:find("[%[%]]") then
        local fresh = M.phaseFromText(ph.text .. " [" .. ph.area .. "]")
        ph.text, ph.area, ph.tags = fresh.text, fresh.area, fresh.tags
      end
    end
  end
end

function M.parseQuests(raw, decho)
  local list, detail, other = {}, nil, {}
  local inPhases = false
  for idx, l in ipairs(raw) do
    local t = trim(l)
    -- "Quest #3390 : Cooking Spaghetti and Pesto (  0/10  complete)."
    -- "Daily Quest #3519 : Daily Quest - Feeding Hungr (  0/1   complete).  [2h 16min 58s]" (a kind in front,
    -- the name cut short, the time left after)
    local left = t:match("%s%[([%dhdmins ]+)%]$")
    local tl = left and trim(t:gsub("%s%[[%dhdmins ]+%]$", "")) or t
    local kind, id, name, done, total = tl:match("^(%a*)%s*Quest #(%d+)%s*:%s*(.-)%s*%(%s*(%d+)/(%d+)%s+complete%)%.?$")
    if id then
      local e = { id = id, name = name, done = tonumber(done), total = tonumber(total), idx = idx, kind = kind ~= "" and kind or nil }
      if left then
        local secs = 0
        for n, u in left:gmatch("(%d+)%s*(%a+)") do
          u = u:lower()
          secs = secs + tonumber(n) * ((u:sub(1, 1) == "d" and 86400) or (u:sub(1, 1) == "h" and 3600) or (u:sub(1, 1) == "m" and 60) or 1)
        end
        if secs > 0 then e.deadline = os.time() + secs end
      end
      list[#list + 1] = e
    else
      -- "is called 'Part-ay!'," or "is called 'Training in the Forest'." (ends with , or .)
      local qid, qname = t:match("^This quest %[(%d+)%] is called '(.*)'[,%.]?%s*$")
      if qid then
        detail = { id = qid, name = qname, desc = {}, phases = {}, rewards = {} }
      elseif detail then
        local lo, hi = t:match("^for %a+ levels (%d+) to (%d+)")
        local master = t:match("^(.-) is the master in charge of this quest")
        local pn, ptext = t:match("^Phase (%d+):%s*(.+)$")
        if lo then detail.levels = lo .. "–" .. hi; detail.who = t:match("^for (%a+)")
        elseif master then detail.master = master
        elseif t:match("^Upon successful completion") then
          detail.inRewards = true
          local rest = t:match("^Upon successful completion of this quest%s*(.*)$") or ""
          if not rest:match("you can receive:?$") and rest ~= "" then detail.rewardNote = rest end
        elseif detail.inRewards and detail.rewardNote and not t:match("time limit") and not t:match(" consists of:$") then
          detail.rewardNote = detail.rewardNote .. " " .. t
          if t:match("%.$") then detail.inRewards = false end
        elseif t:match("^%*The item '.-'%.?$") then
          -- "*The item 'a velocity token'." - a reward, not part of the hint
          detail.rewardItems = detail.rewardItems or {}
          detail.rewardItems[#detail.rewardItems + 1] = t:match("^%*The item '(.-)'")
        elseif detail.inRewards and (t:match("^%*?Up to") or t:match("^[%d,]+ %a")) then
          detail.rewardText = (detail.rewardText and (detail.rewardText .. " ") or "") .. t:gsub("^%*", "")
          if t:match("%.$") then detail.inRewards = false end
        elseif t:match("^You have [%d,]+ Alyrian minutes? remaining") then
          -- an Alyrian minute is 15 real seconds (quest 52: 300 of them = GMCP's deadline 75 minutes later)
          local n = tonumber((t:match("^You have ([%d,]+)"):gsub(",", "")))
          if n then detail.deadline = os.time() + n * M.ALYRIAN_MINUTE end
        elseif t:match("time limit") then detail.limit = t:gsub("%.$", "")
        elseif t:match(" consists of:$") then inPhases = true
        elseif pn then
          local ph = M.phaseFromText(ptext)
          ph.n = tonumber(pn)
          detail.phases[#detail.phases + 1] = ph
        elseif not inPhases and (t ~= "" or (#detail.desc > 0 and detail.desc[#detail.desc] ~= "")) then
          -- keep indentation (lists, continuation lines) and the blank line between paragraphs
          detail.desc[#detail.desc + 1] = (t == "") and "" or rtrim(l)
          -- its colours too (the game highlights commands: "where is cooking-mixing-bowl")
          if t ~= "" and decho and decho[idx] then
            detail.descDecho = detail.descDecho or {}
            detail.descDecho[#detail.desc] = decho[idx]
          end
          -- a paragraph also ends where the game says so without a blank line: its last line ends in
          -- two spaces ("…they need to thrive.  "), or a line too long to be one the game wrapped
          if t ~= "" and (l:match("%S%s%s+$") or ulen(rtrim(l)) > 80) then detail.desc[#detail.desc + 1] = "" end
        elseif t ~= "" then
          other[#other + 1] = t
        end
      elseif t:match("^A total of %[%d+%] quests?") or t:match("^Type QUEST STATUS") then
        other[#other + 1] = { t, idx }
      elseif t ~= "" then
        other[#other + 1] = t
      end
    end
  end
  if detail then
    detail.total = #detail.phases
    detail.done = 0
    for _, p in ipairs(detail.phases) do if p.done then detail.done = detail.done + 1 end end
    -- rewards "Up to 19 quest points, 2 practice points, 6,640 experience points, 0 build points, ..."
    if detail.rewardText then
      local txt = detail.rewardText:gsub("^Up to ", ""):gsub(", and ", ", "):gsub("%.$", "")
      -- items are separated by ", " - the commas inside numbers (6,640) have no space after them
      for part in (txt .. ", "):gmatch("(.-),%s+") do
        local n, what = part:match("^([%d,]+)%s+(.+)$")
        if n then detail.rewards[#detail.rewards + 1] = { n, what } end
      end
      detail.upTo = detail.rewardText:match("^Up to") ~= nil
    end
  end
  return { list = list, detail = detail, other = other }
end

-- keep what we learn about quests, for the tracker
function M.rememberQuests(q, bare)
  local now = os.time()
  -- a plain "quest info" lists your quests - or, with only one, shows that one in full
  local list = q.list
  if #list == 0 and bare and q.detail and q.detail.id then
    list = { { id = q.detail.id, name = q.detail.name, done = q.detail.done, total = q.detail.total } }
  end
  if #list > 0 then
    local active = {}
    for _, e in ipairs(list) do
      local Q = M.quests[e.id] or {}
      -- a list can cut a long name short ("Feeding Hungr"): keep the whole one already known
      if not (Q.name and e.name and Q.name:sub(1, #e.name) == e.name) then Q.name = e.name or Q.name end
      Q.seen = now
      if e.deadline then Q.deadline = e.deadline end
      if e.done then Q.done, Q.total = e.done, e.total end
      Q.active = true
      M.quests[e.id] = Q
      active[e.id] = true
    end
    -- anything else remembered is no longer in your log (finished, turned in or abandoned)
    for id, Q in pairs(M.quests) do if not active[id] then Q.active = false end end
    -- a pinned quest missing from your active list is finished (or abandoned)
    for id in pairs(M.cfg.questPins or {}) do
      if not active[id] then
        M.cfg.questPins[id] = nil
        local Q = M.quests[id]
        M.notifyQuest((Q and Q.name or ("#" .. id)) .. ((Q and questFinished(Q)) and " turned in - unpinned" or " is no longer active - unpinned"))
      end
    end
  end
  if q.detail then
    local d = q.detail
    local Q = M.quests[d.id] or {}
    for k, v in pairs(d) do Q[k] = v end
    if d.total and d.done < d.total then Q.complete = nil end
    Q.seen = now
    Q.active = true
    M.quests[d.id] = Q
    if M.questReplyRequest and M.cfg.questAutoPin ~= false and not (M.cfg.questPins or {})[d.id] then
      M.questReplyRequest = nil
      M.cfg.questPins = M.cfg.questPins or {}
      M.cfg.questPins[d.id] = true
      M.notifyQuest((d.name or ("#" .. d.id)) .. " pinned to the quest HUD (sbo config quest.autopin off to stop)")
    end
  end
  M.cfg.quests = M.quests     -- kept between sessions
  M.saveSettings()
  M.drawQuestTracker()
  -- "sbo quest pin all" waiting for the quest list
  if #list > 0 and M.pinAllPending ~= nil then
    local on = M.pinAllPending
    M.pinAllPending = nil
    M.pinAllFromList = true
    pcall(M.questPin, "all", on)
    M.pinAllFromList = nil
  end
end

-- quest notes go on the quest HUD for a while (where you look for quests), else a line in the game text
function M.notifyQuest(msg)
  if next(M.cfg.questPins or {}) then
    M.hudNote = msg
    pcall(M.drawQuestTracker)
    tempTimer(10, function() if M.hudNote == msg then M.hudNote = nil; pcall(M.drawQuestTracker) end end)
  else
    M.log("<dim_grey>[sbo] " .. msg .. "<reset>")
  end
end

local function questGauge(done, total, width)
  local segs = M.gauge(done, math.max(1, total), width, (done >= total and total > 0) and C.plus or C.slot)
  segs[#segs + 1] = { C.num, string.format(" %d/%d", done, total) }
  return segs
end

-- the next phase still to do
local function nextPhase(Q)
  for _, p in ipairs(Q.phases or {}) do if not p.done then return p end end
end

function M.formatters.quest(raw, width)
  local q = M.parseQuests(raw, M.curDecho)
  if #q.list == 0 and not q.detail then return M.formatters.generic(raw, width) end
  M.rememberQuests(q, M.questReplyBare)
  local out = {}
  local links = {}
  if #q.list > 0 then
    local nameW = 0
    for _, e in ipairs(q.list) do nameW = math.max(nameW, ulen(e.name)) end
    out[#out + 1] = { { C.key, pad("  #", 8) .. pad("Quest", nameW + 2) .. "Progress" } }
    for _, e in ipairs(q.list) do
      local pinned = M.cfg.questPins and M.cfg.questPins[e.id]
      local row = { { M.REC or C.title, pinned and "◆ " or "  " }, { C.dim, pad("#" .. e.id, 6) } }
      addAll(row, M.runsExact(e.idx, e.name) or { { C.item, e.name } })
      row[#row + 1] = { C.text, string.rep(" ", nameW + 2 - ulen(e.name)) }
      addAll(row, questGauge(e.done, e.total, 10))
      local Q = M.quests[e.id]
      local np = Q and nextPhase(Q)
      if np then row[#row + 1] = { C.dim, "   next: " }; row[#row + 1] = { C.text, np.text } end
      out[#out + 1] = row
      local id = e.id
      links[#links + 1] = { "details #" .. id .. " " .. e.name, function() send("quest info " .. id) end }
      links[#links + 1] = { (pinned and "unpin" or "pin") .. " #" .. id .. " to the quest tracker",
        function() M.questPin(id, not (M.cfg.questPins and M.cfg.questPins[id])) end }
    end
  end
  if q.detail then
    local d = q.detail
    local cells = {}
    if d.levels then cells[#cells + 1] = { "Levels", { { C.num, d.levels }, { C.dim, d.who and (" (" .. d.who .. ")") or "" } } } end
    if d.master then cells[#cells + 1] = { "Master", { { C.item, d.master } } } end
    if d.limit then
      local lim = d.limit:find("no time limit") and "none" or d.limit:gsub("^This quest ", "")
      cells[#cells + 1] = { "Time limit", { { C.item, lim } } }
    end
    -- "You have 1984 Alyrian minute remaining" (read into the deadline)
    if d.deadline then
      local left = d.deadline - os.time()
      cells[#cells + 1] = { "Time left", { { M.timeLeftColor(left), M.timeLeftText(left) } } }
    end
    cells[#cells + 1] = { "Progress", questGauge(d.done, d.total, 10) }
    grid(out, cells, width)
    if #d.rewards == 0 and d.rewardNote then
      kvLine(out, "Rewards", 8, { { C.text, d.rewardNote } }, width)
    end
    if #d.rewards > 0 then
      local segs = {}
      if d.upTo then segs[#segs + 1] = { C.dim, "up to " } end
      for i, r in ipairs(d.rewards) do
        if i > 1 then segs[#segs + 1] = { C.dim, " · " } end
        local zero = r[1]:gsub(",", "") == "0"
        segs[#segs + 1] = { zero and C.dim or C.num, r[1] }
        segs[#segs + 1] = { zero and C.dim or C.text, " " .. r[2] }
      end
      kvLine(out, "Rewards", 8, segs, width)
    end
    -- "*The item 'a velocity token'."
    if d.rewardItems and #d.rewardItems > 0 then
      local segs = {}
      for i, it in ipairs(d.rewardItems) do
        if i > 1 then segs[#segs + 1] = { C.dim, " · " } end
        segs[#segs + 1] = { C.item, it }
      end
      kvLine(out, "Items", 8, segs, width)
    end
    if #d.desc > 0 then paragraphs(out, d.desc, width) end
    if #d.phases > 0 then
      subhead(out, "Phases")
      local np = nextPhase(d)
      for _, p in ipairs(d.phases) do
        local mark = p.done and { C.plus, " ✓ " } or (p == np and { M.REC or C.title, " ▶ " } or { C.dim, "   " })
        local row = { mark, { C.dim, string.format("%d. ", p.n) },
                      { p.done and C.dim or (p == np and C.item or C.text), p.text } }
        if p.area then row[#row + 1] = { C.dim, "  [" .. p.area .. "]" } end
        for _, tg in ipairs(p.tags or {}) do row[#row + 1] = { C.dim, " [" .. tg .. "]" } end
        out[#out + 1] = row
      end
    end
    local id = d.id
    local pinned = M.cfg.questPins and M.cfg.questPins[id]
    links[#links + 1] = { (pinned and "unpin" or "pin") .. " to the quest tracker",
      function() M.questPin(id, not (M.cfg.questPins and M.cfg.questPins[id])) end }
  end
  for _, o in ipairs(q.other) do
    if type(o) == "table" then out[#out + 1] = M.runsExact(o[2], o[1]) or { { C.dim, o[1] } }
    else addAll(out, wrapWords(o, width, 0, C.dim)) end
  end
  M.pendingLinks = links   -- picked up by the Inspector page
  local title = q.detail and (q.detail.name .. "  #" .. q.detail.id) or ("Quests (" .. #q.list .. ")")
  return out, title
end

local questFinished
function M.questPin(id, on)
  M.cfg.questPins = M.cfg.questPins or {}
  if id == "all" and not on then
    M.cfg.questPins = {}
  elseif id == "all" then
    -- only the quests "quest info" lists right now: ask the game quietly, pin when it answers
    if not M.pinAllFromList then
      M.pinAllPending = on
      M.quietQuest = true
      M.sendOwn("quest info", false)
      return
    end
    local n = 0
    for qid, Q in pairs(M.quests) do
      if Q.active and not questFinished(Q) then M.cfg.questPins[qid] = true; n = n + 1 end
    end
    M.notifyQuest(n == 0 and "no active quests to pin" or ("pinned " .. n .. " active quest" .. (n == 1 and "" or "s")))
  else
    M.cfg.questPins[tostring(id)] = on or nil
  end
  M.saveSettings()
  M.drawQuestTracker()
  if M.viewPos and M.viewHist[M.viewPos] then M.viewShow() end
end

---------------------------------------------------------------------------
-- Quest HUD: a frameless, translucent panel in a corner of the game screen
---------------------------------------------------------------------------
local function hudEsc(x) return (tostring(x):gsub("&", "&amp;"):gsub("<", "&lt;")) end
local function rgb(c)
  if type(c) == "table" then return string.format("rgb(%d,%d,%d)", c[1], c[2], c[3]) end
  local t = color_table and color_table[c]
  return t and string.format("rgb(%d,%d,%d)", t[1], t[2], t[3]) or "#c0c0c0"
end
local function span(col, txt) return string.format("<span style=\"color:%s\">%s</span>", rgb(col), hudEsc(txt)) end

function questFinished(Q)
  return Q.complete or (Q.total and Q.total > 0 and (Q.done or 0) >= Q.total)
end
M.questFinished = questFinished

-- wrap plain text to `n` characters (word boundaries); continuation lines indented by `ind`
local function hudWrap(text, n, ind)
  local lines, cur = {}, ""
  for word in text:gmatch("%S+") do
    if cur ~= "" and ulen(cur) + 1 + ulen(word) > n then
      lines[#lines + 1] = cur; cur = string.rep(" ", ind or 0) .. word
    else
      cur = (cur == "" or cur:match("^%s+$")) and (cur .. word) or (cur .. " " .. word)
    end
  end
  if cur ~= "" then lines[#lines + 1] = cur end
  return lines
end

-- "<192,192,192:0,0,0>Type <r><0,255,255:0,0,0>where is cooking-mixing-bowl<r>" -> { {nil, "Type "}, {{0,255,255}, "where is …"} }
-- (the game's plain grey is nil: drawn dim like the rest of the hint)
function M.dechoSegs(d)
  local segs, col, pos = {}, nil, 1
  while pos <= #d do
    local a, b, r, g, bl = d:find("<(%d+),(%d+),(%d+):[%d,]*>", pos)
    local ra, rb = d:find("<r>", pos, true)
    local na = math.min(a or math.huge, ra or math.huge)
    if na == math.huge then segs[#segs + 1] = { col, d:sub(pos) }; break end
    if na > pos then segs[#segs + 1] = { col, d:sub(pos, na - 1) } end
    if a and a == na then
      local c = { tonumber(r), tonumber(g), tonumber(bl) }
      col = (c[1] == 192 and c[2] == 192 and c[3] == 192) and nil or c
      pos = b + 1
    else
      col = nil
      pos = rb + 1
    end
  end
  local out = {}
  for _, sg in ipairs(segs) do if sg[2] ~= "" then out[#out + 1] = sg end end
  return out
end

-- wrap coloured segments at n characters; continuation lines indented by ind -> lines of segments
local function segWrap(segs, n, ind)
  -- words, each made of the pieces that touch across a colour change ("pesto" + ".")
  local words, prevGlued = {}, false
  for _, sg in ipairs(segs) do
    local str = sg[2]
    for pos, w in str:gmatch("()(%S+)") do
      if pos == 1 and prevGlued and #words > 0 then
        local last = words[#words]
        last.parts[#last.parts + 1] = { sg[1], w }; last.len = last.len + ulen(w)
      else
        words[#words + 1] = { parts = { { sg[1], w } }, len = ulen(w) }
      end
    end
    prevGlued = str:match("%S$") ~= nil
  end
  local lines, cur, len = {}, {}, 0
  local fresh = true   -- nothing but the indent on this line yet
  for _, w in ipairs(words) do
    if not fresh and len + 1 + w.len > n then
      lines[#lines + 1] = { cur, len }
      cur, len, fresh = { { nil, string.rep(" ", ind or 0) } }, ind or 0, true
    end
    if not fresh then cur[#cur + 1] = { nil, " " }; len = len + 1 end
    for _, p in ipairs(w.parts) do cur[#cur + 1] = p end
    len, fresh = len + w.len, false
  end
  if not fresh then lines[#lines + 1] = { cur, len } end
  return lines
end
M.segWrap = segWrap

-- the quest HUD is HUD_COLS characters wide; its text wraps a few short of that, so a font that draws a
-- little wider than Mudlet's measure of it still fits
local HUD_WRAP, HUD_COLS = 60, 68

-- one quest's lines (html) and their widest width in characters:
-- the name and progress, every step still to do (the next one marked), and optionally the blurb
-- Quest time limits: Q.deadline (a Unix time) from GMCP's quest_info.timer, or from
-- "You have 289 Alyrian minute remaining" (an Alyrian minute is 15 real seconds)
M.ALYRIAN_MINUTE = 15
function M.timeLeftText(sec)
  if sec <= 0 then return "time's up" end
  if sec < 60 then return "<1m left" end
  return M.shortDur(sec) .. " left"
end
function M.timeLeftColor(sec)
  if sec <= 10 * 60 then return C.minus end
  if sec <= 30 * 60 then return C.title end
  return C.dim
end
-- the active quest with the least time left: Q, id, seconds
function M.questSoonest()
  local best, bestId, left
  local nowT = os.time()
  for id, Q in pairs(M.quests or {}) do
    if Q.active ~= false and Q.deadline and Q.deadline > nowT and (not left or Q.deadline - nowT < left) then
      best, bestId, left = Q, id, Q.deadline - nowT
    end
  end
  return best, bestId, left
end

-- "2. Defeat 4/5 of a lost demon · Rune Forest · Group"
function M.phaseLabel(ph)
  return string.format("%d. %s", ph.n, ph.text) .. (ph.area and (" · " .. ph.area) or "")
    .. (ph.tags and (" · " .. table.concat(ph.tags, " · ")) or "")
end

local function questCardHtml(id, Q)
  local html, widest = {}, 0
  local function add(h, w) html[#html + 1] = h; widest = math.max(widest, w) end
  local name = Q.name or ("#" .. id)
  local finished = questFinished(Q)
  local bar = ""
  if Q.total then
    local n = 8
    local done = finished and Q.total or (Q.done or 0)
    local k = math.floor(n * math.min(done, Q.total) / math.max(1, Q.total) + 0.5)
    local col = finished and C.plus or (M.REC or C.slot)
    bar = span(col, string.rep("█", k)) .. span(C.dim, string.rep("░", n - k)) .. span(C.num, string.format(" %d/%d", done, Q.total))
  end
  local titleW = ulen(name) + ulen(id) + 4 + (Q.total and 13 or 0) + (finished and 2 or 0)
  local timeHtml, timeW
  if Q.deadline then
    local left = Q.deadline - os.time()
    local txt = M.timeLeftText(left)
    timeHtml, timeW = span(M.timeLeftColor(left), txt), ulen(txt)
  end
  local together = timeHtml and titleW + 3 + timeW <= HUD_WRAP + 3
  add((finished and span(C.plus, "✓ ") or "") .. span(C.dim, "#" .. id .. " ")
    .. span(finished and C.dim or C.item, name) .. "&nbsp;&nbsp;" .. bar
    .. (together and ("&nbsp;&nbsp;&nbsp;" .. timeHtml) or ""), titleW + (together and (3 + timeW) or 0))
  if timeHtml and not together then add("   " .. timeHtml, timeW + 3) end
  if finished then
    -- who to turn it in to: "Return to Lord Agrippa in time to receive your reward!" (else the quest master)
    local who = Q.turnIn or Q.master
    local tail = (who and (" · return to " .. who) or "") .. " · stays until you quest complete"
    add(span(C.plus, " complete") .. span(C.dim, tail), 9 + ulen(tail))
  elseif Q.phases then
    local first = true
    for _, ph in ipairs(Q.phases) do
      if ph.done then
        -- done: stays in its place, greyed out
        local label = M.phaseLabel(ph)
        for _, l in ipairs(hudWrap(label, HUD_WRAP, ulen(tostring(ph.n)) + 2)) do
          add("   " .. span(C.dim, l), ulen(l) + 3)
        end
      else
        local label = M.phaseLabel(ph)
        for i, l in ipairs(hudWrap(label, HUD_WRAP, ulen(tostring(ph.n)) + 2)) do
          local mark = (i == 1) and (first and span(M.REC or C.title, " ▶ ") or "   ") or "   "
          add(mark .. span(first and C.item or C.text, l), ulen(l) + 3)
        end
        if first then
          -- where the next step is, when Oven can place it
          local ok, room, why = pcall(M.questTarget, ph, id)
          if ok and room then
            -- green: the room the game named for this step; orange: one Oven found (an NPC seen,
            -- where you've killed it, a room by that name on the map) - a good guess, not certain
            local exact = why == M.QUEST_ROOM_EXACT
            local nm = getRoomName(room) or ("#" .. room)
            local go = "  · sbo quest go " .. id
            add("   " .. span(C.dim, "→ ") .. span(exact and C.plus or C.flag, nm) .. span(C.dim, go), ulen(nm) + ulen(go) + 5)
          end
        end
        first = false
      end
    end
  else
    add(span(C.dim, " (click to load its steps)"), 27)
  end
  -- the quest's blurb (often holds hints), dimmed
  if M.cfg.questHudBlurb and Q.desc and #Q.desc > 0 and not finished then
    -- laid out first (paragraphs with a gap between them, lists and headings on their own lines)…
    local lines = {}
    local function put(h, w) lines[#lines + 1] = { h, w } end
    -- each line's words with the game's colours (highlighted commands); plain grey is drawn dim
    local function segsOf(i, l)
      local d = Q.descDecho and Q.descDecho[i]
      local sg = d and M.dechoSegs(d) or nil
      if not sg or #sg == 0 then sg = { { nil, l } } end
      return sg
    end
    local function html(segs, keepSpaces)
      local h = {}
      for _, sg in ipairs(segs) do
        local txt = keepSpaces and sg[2]:gsub(" ", "\194\160") or sg[2]
        h[#h + 1] = span(sg[1] or C.dim, txt)
      end
      return table.concat(h)
    end
    local para = {}
    local function flush()
      if #para > 0 then
        for _, ln in ipairs(segWrap(para, HUD_WRAP, 0)) do put(span(C.dim, " ") .. html(ln[1]), ln[2] + 1) end
        para = {}
      end
    end
    for i, l in ipairs(Q.desc) do
      if trim(l) == "" then
        flush()
        if #lines > 0 and lines[#lines][2] > 0 then put("", 0) end
      elseif l:match("%S%s%s%s+%S") or l:match("^%s%s%s%s+%S") or l:match("^%s*[%*%-] ") or trim(l):match(":$") then
        flush()   -- list lines and "You can find:" headings keep their own line, spacing and all
        local line = rtrim(l)
        if ulen(line) <= HUD_WRAP + 4 then
          local sg = segsOf(i, line)
          put(span(C.dim, " ") .. html(sg, true), ulen(line) + 1)
        else
          for _, ln in ipairs(segWrap(segsOf(i, line), HUD_WRAP, 4)) do put(span(C.dim, " ") .. html(ln[1]), ln[2] + 1) end
        end
      else
        for _, sg in ipairs(segsOf(i, trim(l))) do para[#para + 1] = sg end
        para[#para + 1] = { nil, " " }   -- the next line is a new word, not glued on
      end
    end
    flush()
    while #lines > 0 and lines[#lines][2] == 0 do table.remove(lines) end
    -- what it's worth: the rewards that aren't nothing, and any items
    local worth = {}
    for _, r in ipairs(Q.rewards or {}) do
      if tostring(r[1]):gsub(",", "") ~= "0" then worth[#worth + 1] = { C.num, r[1] .. " " .. r[2] } end
    end
    for _, it in ipairs(Q.rewardItems or {}) do worth[#worth + 1] = { C.item, it } end
    if #worth > 0 then
      local segs = { { C.key, "Rewards " } }
      for k, w in ipairs(worth) do
        if k > 1 then segs[#segs + 1] = { C.dim, " · " } end
        segs[#segs + 1] = w
      end
      put("", 0)
      for _, ln in ipairs(segWrap(segs, HUD_WRAP, 8)) do
        local h = {}
        for _, sg in ipairs(ln[1]) do h[#h + 1] = span(sg[1] or C.dim, sg[2]) end
        put(span(C.dim, " ") .. table.concat(h), ln[2] + 1)
      end
    end
    -- …then folded: the first few lines, unless you've opened it (click the quest)
    local SHOW = 3
    local open = (M.cfg.questHintOpen or {})[tostring(id)]
    add("", 0)
    for i, x in ipairs(lines) do
      if open or i <= SHOW then add(x[1], x[2]) end
    end
    if #lines > SHOW then
      if open then add(span(C.slot, " ▾ click to fold the hint"), 25)
      else
        local more = #lines - SHOW
        add(span(C.slot, string.format(" ▸ %d more line%s · click to open", more, more == 1 and "" or "s")), 32)
      end
    end
  end
  return html, widest
end

local function hudCallbacks(label, id)
  label:setClickCallback(function(ev) M.hudPress(ev, id) end)
  label:setMoveCallback(function(ev) M.hudMove(ev) end)
  label:setReleaseCallback(function(ev) M.hudRelease(ev) end)
  pcall(function() label:setCursor("OpenHand") end)
end

-- the HUD: a frame, with one card per pinned quest inside it (each its own click area)
M.questCardHtml = questCardHtml
function M.drawQuestTracker()
  if M.questContainer then M.questContainer:hide() end   -- the framed window of 0.14.0
  local pins = M.cfg.questPins or {}
  if M.cfg.questHud == false then pins = {} end           -- sbo config quest.hud off
  local ids = {}
  for id in pairs(pins) do ids[#ids + 1] = id end
  M.questCards = M.questCards or {}
  if #ids == 0 then
    if M.questHud then M.questHud:hide() end
    for _, c in ipairs(M.questCards) do c:hide() end
    return
  end
  table.sort(ids, function(a, b2) return tonumber(a) < tonumber(b2) end)
  if not M.questHud then
    M.questHud = Geyser.Label:new({ name = "ovenQuestHud", x = 0, y = 0, width = 300, height = 60 })
    hudCallbacks(M.questHud, nil)
    pcall(function() M.questHud:setToolTip("drag to move · click a quest to open or fold its hint · click a finished quest to clear it · sbo quest refresh re-checks") end)
  end
  local alpha = math.floor(255 * math.max(0, math.min(100, tonumber(M.cfg.questHudOpacity) or 100)) / 100 + 0.5)
  M.questHud:setStyleSheet(string.format([[
    background-color: rgba(8, 8, 12, %d); border: 1px solid rgba(255,255,255,30); border-radius: 6px;]], alpha))
  M.questHud:echo("")
  local font = (pcall(getFont) and getFont()) or "monospace"
  local size = math.max(8, (M.cfg.fontSize or 10) - 1)
  local okF, cw, ch = pcall(calcFontSize, size, font)
  if not okF or not cw then cw, ch = 7, 14 end
  local lineH = ch * 1.35
  local layout, widest, total = {}, 0, 2
  for i, id in ipairs(ids) do
    local card = M.questCards[i]
    if not card then
      card = Geyser.Label:new({ name = "ovenQuestCard" .. i, x = 0, y = 0, width = 100, height = 20 })
      M.questCards[i] = card
    end
    hudCallbacks(card, id)
    local html, w = questCardHtml(id, M.quests[id] or {})
    -- a quest note ("step 1 done") at the top of the HUD for a few seconds
    if i == 1 and M.hudNote then
      table.insert(html, 1, span(C.title, "» " .. M.hudNote))
      w = math.max(w, ulen(M.hudNote) + 2)
    end
    widest = math.max(widest, w)
    card:setStyleSheet(string.format([[
      background-color: transparent; padding: 4px 8px; qproperty-alignment: 'AlignTop | AlignLeft';
      border-bottom: %s;]], (i < #ids) and "1px solid rgba(255,255,255,28)" or "0px"))
    card:rawEcho(string.format("<div style=\"white-space: pre; font-family: '%s', monospace; font-size: %dpt;\">%s</div>",
      font, size, table.concat(html, "<br>")))
    local h = math.ceil(#html * lineH) + 9
    layout[i] = { off = total - 1, h = h }
    total = total + h
  end
  for i = #ids + 1, #M.questCards do M.questCards[i]:hide() end
  M.questCardLayout = layout
  -- a fixed width (wider only for a line that doesn't wrap, like a long quest name)
  M.questHudSize = { w = math.min(600, math.max(HUD_COLS, widest + 3) * cw + 24), h = total }
  M.layoutQuestHud()
  M.questHud:show()
  for i = 1, #ids do M.questCards[i]:show() end
  M.raiseQuestHud()
end

-- keep the quest HUD above every other window
function M.raiseQuestHud()
  if M.questHud and next(M.cfg.questPins or {}) then
    pcall(function() M.questHud:raise() end)
    for i = 1, #(M.questCardLayout or {}) do
      local c = M.questCards and M.questCards[i]
      if c then pcall(function() c:raise() end) end
    end
  end
end

-- dragging the HUD: like Mudlet's own Adjustable.Container, measure the drag with
-- getMousePosition() (window coordinates) from where the button went down
function M.hudPress(ev, id)
  if type(ev) == "table" and ev.button and ev.button ~= "LeftButton" then return end
  local ok, mx, my = pcall(getMousePosition)
  if not ok or not mx then M.questRefresh("all"); return end
  M.hudDrag = { mx = mx, my = my, x = M.questHud:get_x(), y = M.questHud:get_y(), moved = 0, started = os.time(),
                at = type(ev) == "table" and tonumber(ev.y) or nil, id = id }
  pcall(function() M.questHud:setCursor("ClosedHand") end)
  -- some setups (e.g. Linux under WSL) don't deliver mouse-move events while the button is
  -- held, so also follow the cursor with a short timer until the button is released
  if M.hudPoll then killTimer(M.hudPoll) end
  M.hudPoll = tempTimer(0.03, function()
    if not M.hudDrag or os.time() - M.hudDrag.started > 15 then
      if M.hudPoll then killTimer(M.hudPoll); M.hudPoll = nil end
      if M.hudDrag then M.hudRelease() end
      return
    end
    M.hudMove()
  end, true)
end
function M.hudMove(ev)
  local d = M.hudDrag
  if not d then return end
  local ok, mx, my = pcall(getMousePosition)
  if not ok or not mx then return end
  local dx, dy = mx - d.mx, my - d.my
  d.moved = math.max(d.moved, math.abs(dx) + math.abs(dy))
  if d.moved < 4 then return end   -- not a drag yet
  M.cfg.questHudPos = { d.x + dx, d.y + dy }
  M.layoutQuestHud()
end
function M.hudRelease(ev)
  local d = M.hudDrag
  M.hudDrag = nil
  if M.hudPoll then killTimer(M.hudPoll); M.hudPoll = nil end
  pcall(function() M.questHud:setCursor("OpenHand") end)
  if not d then return end
  if d.moved < 4 then
    M.questHudClick(d.id)       -- a click, not a drag
  else
    M.saveSettings()            -- remember where it was dropped
  end
end

-- a click on a quest card: a finished quest is cleared; any other opens or folds its hint (when there's a
-- hint to fold), else refreshes it; a click on the frame (between cards) refreshes them all
function M.questHudClick(id)
  if not id then return M.questRefresh("all") end
  local Q = M.quests[id] or {}
  if questFinished(Q) then
    M.questPin(id, false)
    M.notifyQuest((Q.name or ("#" .. id)) .. " cleared from the quest HUD")
  elseif M.cfg.questHudBlurb and Q.desc and #Q.desc > 0 then
    M.cfg.questHintOpen = M.cfg.questHintOpen or {}
    local k = tostring(id)
    M.cfg.questHintOpen[k] = (not M.cfg.questHintOpen[k]) or nil
    M.saveSettings()
    M.drawQuestTracker()
  else
    M.questRefresh(id)
  end
end

-- "All parts of your quest 'Runic Race' are complete."
function M.questMarkComplete(name)
  for id, Q in pairs(M.quests) do
    if Q.name and Q.name:lower() == name:lower() then
      Q.complete = true
      if Q.total then Q.done = Q.total end
      for _, ph in ipairs(Q.phases or {}) do ph.done = true end
      M.cfg.quests = M.quests
      M.saveSettings()
      M.drawQuestTracker()
      M.questJustDone = id
      if M.cfg.questPins and M.cfg.questPins[id] then
        M.notifyQuest(name .. " complete - turn it in with quest complete")
      end
      return id
    end
  end
end

-- a quest handed in: off the HUD, and out of the active ones
function M.questTurnedIn(name)
  M.questTurnedInAt = os.time()
  for id, Q in pairs(M.quests or {}) do
    if Q.name and Q.name:lower() == name:lower() then
      Q.complete, Q.active, Q.turnedIn = true, false, os.time()
      M.cfg.quests = M.quests
      if (M.cfg.questPins or {})[id] then
        M.cfg.questPins[id] = nil
        M.notifyQuest(Q.name .. " turned in - unpinned")
      end
      M.saveSettings()
      pcall(M.drawQuestTracker)
      return id
    end
  end
end

-- keep the HUD in its corner of the game text area (inside the side borders, under any top line),
-- or where you dragged it (kept on screen)
function M.layoutQuestHud()
  if not M.questHud or not M.questHudSize then return end
  local W = getMainWindowSize()
  local left, right, top = 0, 0, 0
  local ok, b = pcall(getBorderSizes)
  if ok and type(b) == "table" then left, right, top = b.left or 0, b.right or 0, b.top or 0
  else
    local okR, r = pcall(getBorderRight); if okR and r then right = r end
    local okT, t = pcall(getBorderTop); if okT and t then top = t end
  end
  local w, h = M.questHudSize.w, M.questHudSize.h
  local margin = 10
  local x = (M.cfg.questHudSide == "left") and (left + margin) or (W - right - w - margin - 16)
  local y = top + margin
  local pos = M.cfg.questHudPos
  if type(pos) == "table" and tonumber(pos[1]) and tonumber(pos[2]) then
    local _, H = getMainWindowSize()
    x = math.max(0, math.min(tonumber(pos[1]), W - w))
    y = math.max(0, math.min(tonumber(pos[2]), (H or 600) - h))
  end
  M.questHud:move(x, y)
  M.questHud:resize(w, h)
  for i, l in ipairs(M.questCardLayout or {}) do
    local c = M.questCards and M.questCards[i]
    if c then c:move(x + 1, y + 1 + l.off); c:resize(w - 2, l.h) end
  end
end

-- quietly ask the game for a quest's details (nothing shown in the main window)
-- Quest autopilot: find where a quest step points - an NPC Oven has seen, a creature you've
-- killed somewhere, or a room on the map by name (in the step's [Area] when it has one)
local function stripArticle(s)
  s = trim(s or ""):gsub("[%.!,;:]+$", "")
  for _, a in ipairs({ "a certain ", "the ", "a ", "an ", "some " }) do
    if s:lower():sub(1, #a) == a then return s:sub(#a + 1) end
  end
  return s
end

-- the names a step mentions: "Journey to Western Gate of Rune", "Visit Agatha",
-- "Seek out Samara, guardian of ...", "Defeat 5/5 of a risen paladin", "take them to Jeria"
function M.questStepNames(text)
  local t = trim(text or "")
  local out, seen = {}, {}
  local function add(x)
    x = stripArticle(x)
    if x ~= "" and ulen(x) >= 3 and not seen[x:lower()] then seen[x:lower()] = true; out[#out + 1] = x end
  end
  local pats = {
    "^Journey to (.+)$", "^Travel to (.+)$", "^Go to (.+)$", "^Visit (.+)$", "^Speak with (.+)$", "^Talk to (.+)$",
    "^Seek out ([^,]+)", "^Find ([^,]-)'s ", "^Find ([^,]+)", "^Assist (.-) from ", "^Assist ([^,]+)",
    "^Defeat [%d/]+ of (.+)$", "^Defeat ([^,]+)", "^Kill ([^,]+)", "^Slay ([^,]+)",
    " take them to (.+)$", " bring them to (.+)$", " return to (.+)$", " errand for (.+)$", " to (an? [^,]+)$",
    " to (a certain [^,]+)$", " seek out ([^,]+)",
  }
  for _, p in ipairs(pats) do
    local m = t:match(p)
    if m then add((m:gsub(",.*$", ""))) end
  end
  return out
end

M.questTargetCache = M.questTargetCache or {}
M.QUEST_ROOM_EXACT = "the quest's target room"
function M.questTarget(ph, qid)
  if not ph or not ph.text then return end
  -- the game's quest log names the room for many steps
  if qid and ph.n then
    local r = M.gmcpQuestRoom(qid, ph.n)
    if r then return r, M.QUEST_ROOM_EXACT end
  end
  local ck = ph.text .. "|" .. tostring(ph.area)
  local c = M.questTargetCache[ck]
  if c and now() - c.at < 60 then return c.room, c.why end
  local room, why
  local area = ph.area and ph.area:lower()
  local function inArea(id)
    if not area then return true end
    local a = getRoomArea(id)
    local an = a and getRoomAreaName(a)
    return an and an:lower():find(area, 1, true) ~= nil
  end
  for _, name in ipairs(M.questStepNames(ph.text)) do
    local q = name:lower()
    -- an NPC seen in a room
    for _, r in ipairs(M.dbRows("SELECT room, text FROM room_npcs WHERE instr(lower(text), %s) > 0 ORDER BY last DESC", q)) do
      local id = tonumber(r.room)
      if id and roomExists(id) then room, why = id, r.text; break end
    end
    -- a creature you've killed: the room where you've killed it most
    if not room then
      local r = M.dbRow("SELECT room, SUM(n) AS c FROM kills WHERE (key = %s OR instr(key, %s) > 0) AND room IS NOT NULL GROUP BY room ORDER BY c DESC LIMIT 1", q, q)
      local id = r and tonumber(r.room)
      if id and roomExists(id) then room, why = id, "where you've killed " .. name end
    end
    -- a room by that name
    if not room then
      local ok, found = pcall(searchRoom, name)
      if ok and type(found) == "table" then
        local exact, partial
        for key, nm in pairs(found) do
          local id = tonumber(key)
          if id and inArea(id) then
            if nm:lower() == q then exact = exact or id else partial = partial or id end
          end
        end
        room = exact or partial
        if room then why = getRoomName(room) end
      end
    end
    if room then break end
  end
  M.questTargetCache[ck] = { at = now(), room = room, why = why }
  return room, why
end

-- the next step of a quest (or of the first pinned quest that has a step to do)
function M.questNextStep(id)
  local ids = {}
  if id and id ~= "" then ids[1] = tostring(id)
  else for qid in pairs(M.cfg.questPins or {}) do ids[#ids + 1] = qid end table.sort(ids) end
  for _, qid in ipairs(ids) do
    local Q = M.quests[qid]
    for _, ph in ipairs(Q and Q.phases or {}) do
      if not ph.done then return qid, Q, ph end
    end
  end
end

function M.questGo(id)
  local qid, Q, ph = M.questNextStep(id)
  if not ph then
    return M.say(id and id ~= "" and ("quest " .. id .. " has no step to do that Oven knows of (quest info " .. id .. " to load it)")
      or "no pinned quest with a step to do - pin one with sbo quest pin <id>")
  end
  local room, why = M.questTarget(ph, qid)
  if not room then
    local names = M.questStepNames(ph.text)
    return M.say(string.format("#%s step %d: \"%s\" - couldn't place %s yet (see the NPC or room once and try again)",
      qid, ph.n, ph.text, #names > 0 and ("'" .. table.concat(names, "' / '") .. "'") or "it"))
  end
  M.say(string.format("#%s step %d → %s · %s #%d", qid, ph.n, why or "?", getRoomName(room) or "?", room))
  M.mapWalkTo(room)
end

function M.questRefresh(id)
  if id == "all" then
    local ids = {}
    for qid in pairs(M.cfg.questPins or {}) do ids[#ids + 1] = qid end
    for i, qid in ipairs(ids) do tempTimer((i - 1) * 1.5, function() M.questRefresh(qid) end) end
    return
  end
  M.quietQuest = true
  M.sendOwn("quest info " .. id, false)
end

---------------------------------------------------------------- affects
function M.formatters.affects(raw, width)
  local rows, top, other, total = {}, {}, {}, nil
  for _, l in ipairs(raw) do
    local t = trim(l)
    local src, name, lvl, what, by, rest =
      t:match("^(%a[%a ]-):%s+(.-)%s+%-%s+Level%s+(%d+),%s+modifies%s+(%S+)%s+by%s+(%-?%d+)%.?%s*(.*)$")
    if t == "" or t:match("^You are affected by the following") or t:match("^%[.*%]$") then
    elseif src then
      local last = rows[#rows]
      if last and last.src == src and last.name == name and last.lvl == lvl then
        last.mods[#last.mods + 1] = { what, by, rest }
      else
        rows[#rows + 1] = { src = src, name = name, lvl = lvl, mods = { { what, by, rest } } }
      end
    elseif t:match("^Total of") then total = t
    else
      local res = t:match("^%*%s*You are resistant to:%s*(.-)%.?$")
      local vul = t:match("^%*%s*You are vulnerable to:%s*(.-)%.?$")
      local k, v = t:match("^(%a[%a ]-):%s+(.+)$")
      if res then top[#top + 1] = { "Resistant", { { C.plus, res } } }
      elseif vul then top[#top + 1] = { "Vulnerable", { { C.minus, vul } } }
      elseif k and ulen(k) <= 14 then top[#top + 1] = { k, { { C.item, v } } }
      else other[#other + 1] = (t:gsub("^%*%s*", "")) end
    end
  end
  if #rows == 0 and #top == 0 then return M.formatters.generic(raw, width) end
  local out = {}
  for _, tkv in ipairs(top) do kvLine(out, tkv[1], 10, tkv[2], width) end
  if #rows > 0 then
    blank(out)
    local sw, nw = 0, 0
    for _, r in ipairs(rows) do sw = math.max(sw, ulen(r.src)); nw = math.max(nw, ulen(r.name)) end
    nw = math.min(nw, 24)
    local ind = sw + 2 + nw + 2 + 5
    for _, r in ipairs(rows) do
      for n, m in ipairs(r.mods) do
        local row
        if n == 1 then
          row = { { r.src == "Spell" and C.slot or C.key, pad(r.src, sw + 2) },
                  { C.item, pad(r.name, nw + 2) }, { C.dim, pad("L" .. r.lvl, 5) } }
        else
          row = { { C.text, string.rep(" ", ind) } }
        end
        if m[1] == "none" and tonumber(m[2]) == 0 then
          row[#row + 1] = { C.dim, "—" }
        else
          addAll(row, affectSegs(m[1], m[2]))
        end
        if m[3] and m[3] ~= "" then row[#row + 1] = { C.dim, "  " .. m[3] } end
        out[#out + 1] = row
      end
    end
  end
  if #other > 0 then blank(out); for _, o in ipairs(other) do prose(out, { o }, width) end end
  if total then blank(out); out[#out + 1] = { { C.dim, total } } end
  return out, "Affects"
end

---------------------------------------------------------------------------
-- Output
---------------------------------------------------------------------------
local titles = { eq = "Equipment", item = "Look", contents = "Contents" }
M.titles = titles

local function header(kind, target, width, title)
  local t = " " .. (title or ((titles[kind] or kind) .. (target ~= "" and (": " .. target) or ""))) .. " "
  local time = " " .. os.date("%H:%M") .. " "
  local fill = math.max(2, width - ulen(t) - ulen(time) - 2)
  return { { C.rule, "──" }, { C.title, t }, { C.rule, string.rep("─", fill) }, { C.dim, time } }
end

local function render(win, lines)
  for _, segs in ipairs(lines) do
    for _, s in ipairs(segs) do
      local col = s[1]
      if type(col) == "table" then
        setFgColor(win, col[1], col[2], col[3])
      else
        if color_table and not color_table[col] then col = "white" end
        fg(win, col)
      end
      echo(win, s[2])
    end
    resetFormat(win)
    echo(win, "\n")
  end
  resetFormat(win)
end

local function columns(win)
  local ok, n
  if win == "main" then ok, n = pcall(getWindowWrap, "main")
  else ok, n = pcall(getColumnCount, win) end
  n = (ok and tonumber(n)) or 80
  if n < 30 then n = 80 end
  return math.min(n - 1, 110)
end

function M.format(kind, target, raw, width, dechoLines)
  M.curPlain, M.curDecho = raw, dechoLines
  local f = M.formatters[kind] or M.formatters.generic
  local ok, res, title = pcall(f, raw, width)
  if not ok then
    debugc("Oven formatter error: " .. tostring(res))
    return nil
  end
  local lines = { header(kind, target, width, title) }
  addAll(lines, res)
  return lines
end

---------------------------------------------------------------------------
-- (window helpers)
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Static pages: a ScrollBox holding one Label (the page) plus clickable link
-- lines. Unlike a console there is no live split-screen when you scroll.
---------------------------------------------------------------------------
-- segments -> decho text
local function segsToDecho(lines)
  local outl = {}
  for _, segs in ipairs(lines) do
    local t = {}
    for _, sg in ipairs(segs) do
      local c = type(sg[1]) == "table" and sg[1] or (color_table and color_table[sg[1]])
      t[#t + 1] = (c and string.format("<%d,%d,%d>", c[1], c[2], c[3]) or "") .. sg[2]
    end
    outl[#outl + 1] = table.concat(t)
  end
  return outl
end
M.segsToDecho = segsToDecho

local pageStyle = "background-color: black; padding: 6px; qproperty-alignment: 'AlignTop | AlignLeft';"

-- (re)build a page's widgets. Each page shown gets a fresh ScrollBox: it starts at
-- the top, and no stale (unstyled, white) area is left over from a longer page.
local function buildPage(pg)
  if pg.scroll then pcall(function() pg.scroll:delete() end) end
  -- never build a page without its window: Geyser would put it on the main screen at full size
  if not pg.container then return false end
  pg.flip = (pg.flip == "A") and "B" or "A"
  local base = pg.prefix .. pg.flip
  pg.scroll = Geyser.ScrollBox:new({ name = base .. "Scroll", x = 0, y = 0, width = "100%", height = "100%" }, pg.container)
  -- black backdrop under everything (the ScrollBox itself can't be styled)
  pg.backdrop = Geyser.Label:new({ name = base .. "Back", x = 0, y = 0, width = "100%", height = 100 }, pg.scroll)
  pg.backdrop:setStyleSheet("background-color: black;")
  pg.label = Geyser.Label:new({ name = base .. "Label", x = 0, y = 0, width = "100%", height = 40 }, pg.scroll)
  pg.label:setStyleSheet(pageStyle)
  pg.links = {}
  return true
end

-- remove page widgets left over from an earlier version in this session
-- (0.10.0 pages didn't know their window, and 0.10.1-0.10.2 rebuilt them full-screen)
function M.dropPages()
  for _, key in ipairs({ "viewPg", "helpPg", "questPg" }) do
    local pg = M[key]
    if pg and pg.scroll then pcall(function() pg.scroll:delete() end) end
    M[key] = nil
  end
  -- the 0.9.3-0.9.11 help panel too (it lived in the help window, but rebuild it the current way)
  if M.helpScroll then pcall(function() M.helpScroll:delete() end) end
  M.helpScroll, M.helpLabel, M.helpLinks, M.helpSpacer = nil, nil, nil, nil
  for _, n in ipairs({ "ovenHelpAScroll", "ovenHelpBScroll", "ovenViewAScroll", "ovenViewBScroll" }) do
    pcall(deleteScrollBox, n)
  end
end

function M.newPage(prefix, container)
  local pg = { prefix = prefix, container = container, links = {} }
  buildPage(pg)
  return pg
end

local function pageFont()
  local font = (pcall(getFont) and getFont()) or "monospace"
  local size = M.cfg.fontSize
  local ok, cw, ch = pcall(calcFontSize, size, font)
  if not ok or not cw then cw, ch = 8, 16 end
  return font, size, cw, ch
end

-- characters that fit across a page
function M.pageCols(pg)
  local _, _, cw = pageFont()
  local okW, boxW = pcall(function() return pg.scroll:get_width() end)
  return math.max(30, math.floor((((okW and boxW) or 600) - 40) / cw))
end

-- runs -> decho text
local function runsToDecho(runs)
  local t = {}
  for _, r in ipairs(runs) do
    t[#t + 1] = (r[1] and string.format("<%d,%d,%d>", r[1][1], r[1][2], r[1][3]) or "<192,192,192>") .. r[2]
  end
  return table.concat(t)
end

-- characters a..b (inclusive) of a run list
local function sliceRuns(runs, a, b)
  local out, pos = {}, 0
  for _, r in ipairs(runs) do
    local n = ulen(r[2])
    local x, y = math.max(a, pos + 1), math.min(b, pos + n)
    if x <= y then out[#out + 1] = { r[1], M.usub(r[2], x - pos, y - pos) } end
    pos = pos + n
  end
  return out
end

-- wrap one decho line to `cols` characters, keeping its colours; continuation
-- lines keep the original indent. Returns a list of decho lines.
function M.wrapDecho(d, cols)
  local runs = M.dechoRuns(d)
  local plain = ""
  for _, r in ipairs(runs) do plain = plain .. r[2] end
  local len = ulen(plain)
  if len <= cols then return { d } end
  local indent = math.min(#(plain:match("^(%s*)")), math.floor(cols / 2))
  local out, pos, first = {}, 1, true
  while pos <= len do
    local width = first and cols or (cols - indent)
    local stop = pos + width - 1
    if stop >= len then stop = len
    else
      -- break at the last space inside the width, if there is one
      local chunk = M.usub(plain, pos, stop + 1)
      local lastSpace
      for i = ulen(chunk), 2, -1 do
        if M.usub(chunk, i, i) == " " then lastSpace = i; break end
      end
      if lastSpace then stop = pos + lastSpace - 2 end
    end
    local piece = runsToDecho(sliceRuns(runs, pos, stop))
    out[#out + 1] = (first and "" or string.rep(" ", indent)) .. piece
    first = false
    pos = stop + 1
    while pos <= len and M.usub(plain, pos, pos) == " " do pos = pos + 1 end   -- skip the break's spaces
  end
  return out
end

-- lines: decho ("decho") or cecho ("cecho") strings; links: { {text, function}, ... }
function M.pageShow(pg, lines, fmt, links)
  local font, size, cw, ch = pageFont()
  local cols = M.pageCols(pg)
  -- wrap here (keeping colours) so the page has an exact number of lines and
  -- Qt doesn't wrap on its own: then the measured height is exact too
  local html, nLines = {}, 0
  for _, l in ipairs(lines) do
    if fmt == "cecho" then l = M.cechoToDecho(l) end
    for _, w in ipairs(M.wrapDecho(l, cols)) do
      html[#html + 1] = (w == "") and "" or decho2html(w)
      nLines = nLines + 1
    end
  end
  local doc = string.format(
    "<div style=\"white-space: pre; font-family: '%s', monospace; font-size: %dpt; color: #c0c0c0;\">%s</div>",
    font, size, table.concat(html, "\n"))
  if buildPage(pg) == false then return end
  pg.label:rawEcho(doc)
  -- height: Qt's measurement of the (already wrapped) page, else an estimate
  local lineH = ch * 1.25
  local okH, _, hintH = pcall(function() return pg.label:getSizeHint() end)
  local pageH
  if okH and tonumber(hintH) and hintH > 0 then
    pageH = math.ceil(hintH) + 4
    if nLines > 0 then lineH = math.max(ch, hintH / nLines) end
  else
    pageH = math.ceil(nLines * lineH + 12)
  end
  local rowH = math.ceil(lineH)
  links = links or {}
  pg.label:resize(nil, pageH)
  -- clickable lines under the page (labels can't hold links, so each is its own label)
  local linkY = pageH
  for i, ln in ipairs(links) do
    local lab = pg.links[i]
    if not lab then
      lab = Geyser.Label:new({ name = pg.prefix .. pg.flip .. "Link" .. i, x = 0, y = 0, width = "100%", height = 20 }, pg.scroll)
      pg.links[i] = lab
    end
    lab:setStyleSheet(string.format([[
      QLabel { background-color: black; color: #87cefa; padding-left: 6px;
               font-family: '%s', monospace; font-size: %dpt; }
      QLabel::hover { color: #ffffff; text-decoration: underline; }]], font, size))
    pcall(function() lab:setCursor("PointingHand") end)
    -- long entries wrap onto extra rows (indented under the text) instead of being cut off
    local hang = math.min(8, #(ln[1]:match("^(%[%s*%d+%s*%]%s*)") or "  "))
    local rowsOf = M.wrapDecho(string.rep(" ", hang) .. ln[1], math.max(20, cols - 2))
    local htmlRows = {}
    for r, w in ipairs(rowsOf) do
      w = w:gsub("<%d+,%d+,%d+>", "")                       -- plain text (link colour comes from the style)
      if r == 1 then w = M.usub(w, hang + 1, ulen(w)) end   -- the first row isn't indented
      local esc = w:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(" ", "&nbsp;")
      htmlRows[r] = esc
    end
    lab:echo(table.concat(htmlRows, "<br>"))
    local fn = ln[2]
    lab:setClickCallback(function() fn() end)
    lab:move(0, linkY)
    lab:resize("100%", rowH * #rowsOf)
    linkY = linkY + rowH * #rowsOf
    lab:show()
  end
  for i = #links + 1, #pg.links do pg.links[i]:hide() end
  -- backdrop: as tall as the content (plus a little room) and at least the visible area
  local okV, visH = pcall(function() return pg.scroll:get_height() end)
  local contentH = linkY + 2 * rowH
  pg.backdrop:resize("100%", math.max(contentH, (okV and tonumber(visH)) or 0))
end

---------------------------------------------------------------------------
-- Inspector window: one result at a time (eq, item, score, compare…), with ◀ older / newer ▶
---------------------------------------------------------------------------
function M.createWindow()
  if not M.container then
    M.container = Adjustable.Container:new({
      name = "ovenViewer",
      titleText = "Inspector",
      x = "-62%", y = "4%", width = "36%", height = "50%",
      adjLabelstyle = "background-color: rgba(20,20,28,235); border: 1px solid #555; border-radius: 4px;",
      titleTxtColor = "#e6c35c",
    })
    M.panelPlace("ovenViewer", M.container)
  end
  if M.console then M.console:hide() end   -- console used by versions before 0.10
  M.applyTabs()
end

-- Tabs along the top of the Inspector window. Each tab is its own page; whatever arrives for a
-- tab (an item, a help page, the session) brings it to the front.
M.TABS = { { key = "view", title = "Inspector" }, { key = "help", title = "Help" }, { key = "log", title = "Log" },
           { key = "chat", title = "Chat" }, { key = "notes", title = "Notes" } }
local TABS_ID = "ovenTabs3"   -- new widget names whenever the set of tabs changes (an update mid-session)
local tabStyle = [[
  QLabel { background-color: rgba(24,24,32,255); color: #808080; border: 1px solid #333; border-bottom: none;
           border-top-left-radius: 4px; border-top-right-radius: 4px; padding: 0 10px; margin-right: 2px; }
  QLabel::hover { color: #e0e0e0; }]]
local tabOnStyle = [[
  QLabel { background-color: black; color: #e6c35c; border: 1px solid #555; border-bottom: none;
           border-top-left-radius: 4px; border-top-right-radius: 4px; padding: 0 10px; margin-right: 2px; }]]

function M.buildTabs()
  if M.tabBox and M.tabsId == TABS_ID then return end
  if M.tabBox then pcall(function() M.tabBox:hide() end) end   -- tabs from before an update
  M.tabsId = TABS_ID
  M.tabBox = Geyser.VBox:new({ name = TABS_ID .. "Box", x = 0, y = 0, width = "100%", height = "100%" }, M.container)
  M.tabBar = Geyser.HBox:new({ name = TABS_ID .. "Bar", height = 24, v_policy = Geyser.Fixed }, M.tabBox)
  M.tabBody = Geyser.Container:new({ name = TABS_ID .. "Body" }, M.tabBox)
  M.tabLabels, M.tabPages = {}, {}
  for _, t in ipairs(M.TABS) do
    local key = t.key
    local lab = Geyser.Label:new({ name = TABS_ID .. "_" .. key, width = 96, h_policy = Geyser.Fixed }, M.tabBar)
    lab:echo("<center>" .. t.title .. "</center>")
    pcall(function() lab:setCursor("PointingHand") end)
    lab:setClickCallback(function() M.tabShow(key) end)
    M.tabLabels[key] = lab
    M.tabPages[key] = Geyser.Container:new({ name = TABS_ID .. "Page_" .. key, x = 0, y = 0, width = "100%", height = "100%" }, M.tabBody)
  end
  pcall(M.buildChat, M.tabPages.chat)
  pcall(M.buildNotes, M.tabPages.notes)
  -- the rest of the bar stays empty
  M.tabFill = Geyser.Label:new({ name = TABS_ID .. "Fill" }, M.tabBar)
  M.tabFill:setStyleSheet("background-color: rgba(20,20,28,0); border-bottom: 1px solid #555;")
end

-- point each page at its tab (tabs on) or at its own window (tabs off)
local function movePage(pg, container)
  if not pg then return end
  if pg.container ~= container and pg.scroll then pcall(function() pg.scroll:delete() end); pg.scroll = nil end
  pg.container = container
end
function M.applyTabs()
  if M.cfg.tabs then
    M.buildTabs()
    M.tabBox:show()
    if not M.viewPg then M.viewPg = M.newPage("ovenView", M.tabPages.view) end
    movePage(M.viewPg, M.tabPages.view)
    movePage(M.helpPg, M.tabPages.help)
    if M.helpContainer then M.helpContainer:hide() end
    if not M.logPg then M.logPg = M.newPage("ovenLog", M.tabPages.log) end
    movePage(M.logPg, M.tabPages.log)
    M.tabShow(M.tabOn or "view", true)
  else
    if M.tabBox then M.tabBox:hide() end
    if not M.viewPg then M.viewPg = M.newPage("ovenView", M.container) end
    movePage(M.viewPg, M.container)
    if M.helpPg and M.helpContainer then movePage(M.helpPg, M.helpContainer) end
  end
end

M.tabNew = M.tabNew or {}
function M.tabShow(key, quiet)
  if not M.cfg.tabs or not M.tabPages or not M.tabPages[key] then return end
  M.tabOn = key
  M.tabNew[key] = nil
  for _, t in ipairs(M.TABS) do
    local on = t.key == key
    if on then M.tabPages[t.key]:show() else M.tabPages[t.key]:hide() end
    M.tabLabels[t.key]:setStyleSheet(on and tabOnStyle or tabStyle)
    -- a tab with something new in it that you haven't looked at (chat keeps its own count)
    if t.key ~= "chat" then
      M.tabLabels[t.key]:echo("<center>" .. t.title .. (M.tabNew[t.key] and " •" or "") .. "</center>")
    end
  end
  -- a tab nothing has been shown in yet
  if not quiet then
    if key == "view" and not M.viewShown then M.viewShow()
    elseif key == "log" and not M.logShown then M.logAdd(M.sessionLines(M.pageCols(M.logPg)), M.logLinks())
    elseif key == "chat" then M.chatSeen()
    elseif key == "help" and not M.helpShown then
      M.helpPage("Help", { "<128,128,128>Game help pages open here - try help classes, or sbo for Oven's commands." }, "decho")
    end
  end
  if M.raiseQuestHud then M.raiseQuestHud() end
end

-- putting something in a tab: draw it with the tab in front, then leave it there - or, with
-- sbo config tabs.auto off, go back to the tab you were on and mark this one
local function tabBegin(key) local prev = M.tabOn; M.tabShow(key, true); return prev end
local function tabEnd(key, prev, asked)
  if asked or M.cfg.tabAuto ~= false or not prev or prev == key then return M.tabShow(key) end
  M.tabNew[key] = true
  M.tabShow(prev, true)
end
M.tabBegin, M.tabEnd = tabBegin, tabEnd

-- Log tab: session, kills, loot, deaths - with links between them
function M.logLinks()
  return {
    { "session", function() M.command("log session") end },
    { "kills", function() M.command("log kills") end },
    { "loot", function() M.command("log loot") end },
    { "deaths", function() M.command("log deaths") end },
  }
end
function M.logAdd(lines, links)
  if not M.cfg.tabs then return M.viewAdd({ lines = lines, links = links or {} }) end
  M.createWindow()
  M.container:show()
  M.logShown = true
  local all = {}
  for _, l in ipairs(links or {}) do all[#all + 1] = l end
  for _, l in ipairs(M.logLinks()) do all[#all + 1] = l end
  local prev = tabBegin("log")
  M.pageShow(M.logPg, segsToDecho(lines), "decho", all)
  tabEnd("log", prev, true)   -- only ever from an sbo command you typed
end
-- an Oven report for the Inspector (upgrades, build, compare, map find, marks): in the Inspector,
-- and on the main screen too while sbo mirror inspector is on (or when there's no window)
function M.viewOut(lines, links)
  if M.cfg.window then
    M.viewAdd({ lines = lines, links = links or {} })
    if M.cfg.mirror.view == false then return end
  end
  render("main", lines)
end

-- a Log report: make(width) -> lines, links. In the Log tab (and on the main screen too with
-- sbo mirror log on), or on the main screen when the window is off
function M.logOut(make)
  if M.cfg.window then
    local lines, links = make(M.logCols())
    M.logAdd(lines, links)
    if not M.cfg.mirror.log then return end
  end
  render("main", (make(columns("main"))))
end
function M.logCols() return (M.cfg.tabs and M.logPg) and math.min(M.pageCols(M.logPg), 110) or M.viewCols() end

function M.viewCols()
  M.createWindow()
  return math.min(M.pageCols(M.viewPg), 110)
end

M.viewHist = M.viewHist or {}
function M.viewAdd(entry)
  local h = M.viewHist
  h[#h + 1] = entry
  while #h > 30 do table.remove(h, 1) end
  M.viewPos = #h
  M.viewShow()
end

function M.viewShow()
  M.viewShown = true
  M.createWindow()
  M.container:show()
  local h, pos = M.viewHist, M.viewPos or #M.viewHist
  local e = h[pos]
  if not e then return M.pageShow(M.viewPg, { "<128,128,128>Nothing baked yet - try eq, i, score or look at an item." }, "decho") end
  local links = {}
  for _, l in ipairs(e.links or {}) do links[#links + 1] = l end
  if pos > 1 then
    links[#links + 1] = { "◀ older  (" .. (pos - 1) .. " more)", function() M.viewPos = pos - 1; M.viewShow() end }
  end
  if pos < #h then
    links[#links + 1] = { "newer ▶  (" .. (#h - pos) .. " more)", function() M.viewPos = pos + 1; M.viewShow() end }
  end
  local prev = M.cfg.tabs and tabBegin("view")
  M.pageShow(M.viewPg, segsToDecho(e.lines), "decho", links)
  if M.cfg.tabs then tabEnd("view", prev) end
  if M.raiseQuestHud then M.raiseQuestHud() end
end

---------------------------------------------------------------------------
-- Help window: game help pages exactly as sent (colours and layout kept)
---------------------------------------------------------------------------
function M.createHelpWindow()
  if M.cfg.tabs then
    M.createWindow()
    if not M.helpPg then M.helpPg = M.newPage("ovenHelp", M.tabPages.help) end
    M.helpPg.container = M.tabPages.help
    return
  end
  if not M.helpContainer then
    M.helpContainer = Adjustable.Container:new({
      name = "ovenHelp",
      titleText = "help",
      x = "2%", y = "4%", width = "45%", height = "70%",
      adjLabelstyle = "background-color: rgba(20,20,28,235); border: 1px solid #555; border-radius: 4px;",
      titleTxtColor = "#e6c35c",
    })
    M.panelPlace("ovenHelp", M.helpContainer)
  end
  if M.helpConsole then M.helpConsole:hide() end   -- console used by versions before 0.9.3
  if M.helpLabel and not M.helpPg then
    -- page built by 0.9.3 - 0.9.11: reuse its widgets
    M.helpPg = { prefix = "ovenHelp", container = M.helpContainer, scroll = M.helpScroll, label = M.helpLabel, links = M.helpLinks or {} }
  end
  if not M.helpPg then M.helpPg = M.newPage("ovenHelp", M.helpContainer) end
  M.helpPg.container = M.helpContainer
end

-- cecho text -> decho text (colour names -> r,g,b)
function M.cechoToDecho(l)
  return (l:gsub("<([%w_]+)>", function(n)
    if n == "reset" then return "<192,192,192>" end
    local c = color_table and color_table[n]
    return c and string.format("<%d,%d,%d>", c[1], c[2], c[3]) or nil
  end))
end

-- show a page in the help window: title + lines in decho or cecho format;
-- links: { {text, function}, ... }
function M.helpPage(title, lines, fmt, links)
  M.createHelpWindow()
  if M.cfg.tabs then
    M.container:show()
    M.helpShown = true
    M.helpPrev = tabBegin("help")
  else
    M.helpContainer:show()
  end
  local cols = M.pageCols(M.helpPg)
  local all = { segsToDecho({ header("help", "", math.min(cols, 100), title) })[1] }
  for _, l in ipairs(lines) do all[#all + 1] = (fmt == "cecho") and M.cechoToDecho(l) or l end
  M.pageShow(M.helpPg, all, "decho", links)
  if M.cfg.tabs then tabEnd("help", M.helpPrev) end
  if M.raiseQuestHud then M.raiseQuestHud() end
end

-- "[1024] set - toggles ..." -> help 1024 ; " remove - remove an item" -> help remove
function M.helpLinkFor(plain)
  local id = plain:match("^%s*%[%s*(%d+)%s*%]")
  if id then return "help " .. id end
  local topic = plain:match("^%s+([%a][%w%s,'%-]-)%s+%-%s")
  if topic then
    topic = trim(topic:match("^([^,]+)") or topic)   -- "hold, wield, equip - ..." -> hold
    return "help " .. topic
  end
end

function M.showHelp(topic, dechoLines)
  local body, links, inSeeAlso, lastWasLink = {}, {}, false, false
  for _, d in ipairs(dechoLines) do
    local plain = ""
    for _, run in ipairs(M.dechoRuns(d)) do plain = plain .. run[2] end
    local blankLine = trim(plain) == ""
    local prevBlank = #body > 0 and trim(body[#body]:gsub("<[^<>]*>", "")) == ""
    if inSeeAlso and lastWasLink and not blankLine and not M.helpLinkFor(plain) then
      -- an entry that wrapped onto a second line: "... through which you may trade" / "items to other players"
      links[#links][1] = links[#links][1] .. " " .. trim(plain)
    elseif blankLine and (prevBlank or inSeeAlso) then
      -- collapse runs of blank lines; none inside SEE ALSO
    elseif plain:match("^%s*SEE ALSO:?%s*$") then
      inSeeAlso = true; body[#body + 1] = d
    elseif (inSeeAlso and M.helpLinkFor(plain))
        -- topic lists outside SEE ALSO, e.g. search results: " [1087] general object ..."
        or plain:match("^%s+%[%s*%d+%s*%]") then
      local cmd = M.helpLinkFor(plain)
      links[#links + 1] = { trim(plain), function() send(cmd) end }
      lastWasLink = true
    else
      body[#body + 1] = d
      lastWasLink = false
    end
  end
  -- drop trailing blank lines before the links
  while #links > 0 and #body > 0 and trim(body[#body]:gsub("<[^<>]*>", "")) == "" do table.remove(body) end
  M.helpPage("Help" .. ((topic and topic ~= "") and (": " .. topic) or ""), body, "decho", links)
end

function M.showWindow(on)
  if on then
    M.createWindow()
    M.container:show()
    if not M.viewHist[1] then M.viewShow() end
  elseif M.container then
    M.container:hide()
  end
end

---------------------------------------------------------------------------
-- Item memory + comparison
---------------------------------------------------------------------------
M.itemsFile = getMudletHomeDir() .. "/oven_items.lua"
M.items = M.items or {}      -- name -> parsed item
M.recent = M.recent or {}    -- names, most recent last
M.eqNames = M.eqNames or {}  -- names of what you wore at the last `eq`

-- items live in the database; M.items is a cache that reads an item the first time it's asked for
local function itemCache()
  return setmetatable({}, { __index = function(t, name)
    if type(name) ~= "string" then return nil end
    local r = M.dbRow("SELECT data FROM items WHERE name = %s", name)
    local it = r and M.deser(r.data)
    if it then rawset(t, name, it) end
    return it
  end })
end

function M.loadItems()
  migrate(M.itemsFile, "softbunsos_items.lua")
  migrate(M.itemsFile, "mmformat_items.lua")
  M.items = itemCache()
  M.recent = M.dbGet("recent") or {}
  M.eqNames = M.dbGet("eq") or {}
  M.pinned = M.dbGet("pinned")
end

-- the small lists that go with items (recent, what you wear, the pinned one)
function M.saveItems()
  M.dbSet("recent", M.recent)
  M.dbSet("eq", M.eqNames)
  M.dbSet("pinned", M.pinned or false)
end

-- an item's numbers, one row per stat, so items can be ranked with a query (gear score)
function M.storeItem(it)
  M.dbx("INSERT OR REPLACE INTO items (name, type, level, worn, seen, data) VALUES (%s, %s, %s, %s, %s, %s)",
    it.name, it.type, tonumber(it.level), it.worn, it.seen, M.ser(it))
  M.dbx("DELETE FROM item_stats WHERE name = %s", it.name)
  local sums = {}
  for _, list in ipairs({ it.affects or {}, it.relicAffects or {} }) do
    for _, a in ipairs(list) do
      local stat, v = a[1], tonumber(a[2])
      if stat and v then sums[stat] = (sums[stat] or 0) + v end
    end
  end
  if tonumber(it.ar) then sums.ar = (sums.ar or 0) + tonumber(it.ar) end
  for stat, v in pairs(sums) do
    M.dbx("INSERT INTO item_stats (name, stat, value) VALUES (%s, %s, %s)", it.name, stat, v)
  end
end

function M.remember(it)
  local copy = {}
  for k, v in pairs(it) do
    if k ~= "desc" and k ~= "other" and k ~= "header" and k ~= "relics" then copy[k] = v end
  end
  copy.seen = os.time()
  rawset(M.items, it.name, copy)
  M.storeItem(copy)
  for i = #M.recent, 1, -1 do if M.recent[i] == it.name then table.remove(M.recent, i) end end
  M.recent[#M.recent + 1] = it.name
  while #M.recent > 40 do table.remove(M.recent, 1) end
  M.saveItems()
end

function M.updateEqNames(raw)
  local names = {}
  for _, l in ipairs(raw) do
    local _, item = parseSlot(l)
    if item then names[#names + 1] = (stripConds(item)) end
  end
  if #names > 0 then M.eqNames = names; M.saveItems() end
end

-- find a remembered item by (part of) its name; most recently seen wins
function M.findItem(q)
  q = trim(q or ""):lower()
  if q == "" then return nil end
  if M.items[q] then return M.items[q] end
  for i = #M.recent, 1, -1 do
    local n = M.recent[i]
    if M.items[n] and n:lower():find(q, 1, true) then return M.items[n] end
  end
  local r = M.dbRow("SELECT name FROM items WHERE instr(lower(name), %s) > 0 ORDER BY seen DESC LIMIT 1", q)
  return r and M.items[r.name]
end

local rank = { min = 1, minimal = 1, low = 2, med = 3, medium = 3, moderate = 3, high = 4, max = 5, maximum = 5 }
local function num(v)
  if v == nil then return nil end
  return tonumber((tostring(v):gsub(",", ""):gsub("%%$", "")))
end
local function pebbles(it) return it.weight and (num(it.weight[1]) or 0) * 1000 + (num(it.weight[2]) or 0) end

-- rows: {label, aText, bText, deltaText, better}  better: 1 = B better, -1 = A better, 0 = same / n.a.
function M.compareRows(a, b)
  local rows = {}
  local function numRow(label, av, bv, mode, always)
    if av == nil and bv == nil then return end
    local an, bn = num(av) or (av == nil and 0 or nil), num(bv) or (bv == nil and 0 or nil)
    local d = (an and bn) and (bn - an) or nil
    if d == 0 and not always then
      rows[#rows + 1] = { label, tostring(av or "—"), tostring(bv or "—"), "=", 0 }; return
    end
    local better = 0
    if d and mode == "high" then better = d > 0 and 1 or (d < 0 and -1 or 0)
    elseif d and mode == "low" then better = d < 0 and 1 or (d > 0 and -1 or 0) end
    local function commas(n)
      local str = tostring(math.abs(n)):gsub("%.0+$", "")
      local int, frac = str:match("^(%d+)(.*)$")
      int = int:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
      return (n < 0 and "-" or "+") .. int .. frac
    end
    local dt = d and (d == 0 and "=" or commas(d)) or ""
    rows[#rows + 1] = { label, tostring(av or "—"), tostring(bv or "—"), dt, better }
  end
  local function rankRow(label, av, bv)
    if av == nil and bv == nil then return end
    local ar, br = rank[(av or ""):lower()], rank[(bv or ""):lower()]
    local better = (ar and br) and ((br > ar) and 1 or (br < ar and -1 or 0)) or 0
    rows[#rows + 1] = { label, av or "—", bv or "—", better == 0 and (av == bv and "=" or "") or (better > 0 and "better" or "worse"), better }
  end
  local function textRow(label, av, bv, always)
    if av == nil and bv == nil then return end
    if av == bv and not always then return end
    rows[#rows + 1] = { label, av or "—", bv or "—", av == bv and "=" or "", 0 }
  end
  textRow("Type", a.type, b.type, true)
  textRow("Worn", a.worn, b.worn, true)
  numRow("Level", a.level, b.level)
  numRow("Armor", a.ar, b.ar, "high")
  if M.cfg.arRate and (a.ar or b.ar) then
    local d = (tonumber(b.ar) or 0) - (tonumber(a.ar) or 0)
    if d ~= 0 then
      rows[#rows + 1] = { "  damage", "", "", string.format("%+.2f%%", -d * M.cfg.arRate), d > 0 and 1 or -1 }
    end
  end
  if a.weight or b.weight then
    local aw, bw = pebbles(a), pebbles(b)
    local fmt = function(it) return it.weight and (it.weight[1] .. "st " .. it.weight[2] .. "pb") or "—" end
    local better = (aw and bw) and ((bw < aw) and 1 or (bw > aw and -1 or 0)) or 0
    rows[#rows + 1] = { "Weight", fmt(a), fmt(b), better == 0 and "=" or (better > 0 and "lighter" or "heavier"), better }
  end
  numRow("Value", a.value, b.value)
  numRow("Repairs", a.repairs, b.repairs, "high")
  numRow("Slots", a.slots, b.slots, "low")
  -- extras such as Max level / Spell
  local ex = {}
  for _, it in ipairs({ a, b }) do
    for _, x in ipairs(it.extra or {}) do
      local txt = "" for _, sg in ipairs(x[2]) do txt = txt .. sg[2] end
      ex[x[1]] = ex[x[1]] or {}
      ex[x[1]][it == a and 1 or 2] = trim(txt)
    end
  end
  for k, v in pairs(ex) do
    if k == "Max level" or k == "Min level" then numRow(k, v[1], v[2]) else textRow(k, v[1], v[2]) end
  end
  textRow("Attribs", a.attrs, b.attrs)
  textRow("Special", a.special, b.special)
  -- affects (main + relics)
  local function affs(it, list, suffix, into)
    for _, af in ipairs(it[list] or {}) do
      local k = af[1] .. suffix
      into[k] = (into[k] or 0) + (num(af[2]) or 0)
    end
  end
  for _, spec in ipairs({ { "affects", "" }, { "relicAffects", " (relic)" } }) do
    local A, B, keys = {}, {}, {}
    affs(a, spec[1], spec[2], A); affs(b, spec[1], spec[2], B)
    for k in pairs(A) do keys[k] = true end
    for k in pairs(B) do keys[k] = true end
    local sorted = {}
    for k in pairs(keys) do sorted[#sorted + 1] = k end
    table.sort(sorted)
    for _, k in ipairs(sorted) do
      local function sg(v) return v and ((v > 0 and "+" or "") .. v) or nil end
      numRow(k, sg(A[k]), sg(B[k]), "high", true)
    end
  end
  -- weapons
  local wa, wb = a.weapon, b.weapon
  if wa or wb then
    wa, wb = wa or {}, wb or {}
    rankRow("Dmg level", wa.dmgLevel, wb.dmgLevel)
    textRow("Dmg type", wa.dmgType, wb.dmgType, true)
    rankRow("Accuracy", wa.accuracy, wb.accuracy)
    rankRow("Range", wa.range, wb.range)
    rankRow("Crit", wa.critChance, wb.critChance)
    local sa, sb, order = {}, {}, {}
    for _, st in ipairs(wa.stats or {}) do sa[st[1]] = st[2]; order[#order + 1] = st[1] end
    for _, st in ipairs(wb.stats or {}) do
      sb[st[1]] = st[2]
      if not sa[st[1]] then order[#order + 1] = st[1] end
    end
    for _, k in ipairs(order) do numRow(k, sa[k], sb[k], "high", true) end
  end
  return rows
end

---------------------------------------------------------------------------
-- Gear score: each stat times your build's weight for it, added up. Builds start from your
-- class; any weight can be changed, and you can keep several builds and switch between them.
-- Weights are per point: +1 strength counts 3 in a monk build, +1 hp counts 0.2.
-- A key ending in * covers a family (damage-* = every damage-... stat).
---------------------------------------------------------------------------
M.buildPresets = {
  -- help monk: a hybrid - spells (cause light, cure light, faerie fire, pressure points) and martial arts,
  -- with nunchaku and staff; its primary attribute (knowledge) is put on top once that page is read
  monk     = { strength = 2.5, agility = 2.5, knowledge = 3, wisdom = 1.5, vitality = 1.5, ar = 3, hp = 0.2, ["hp-regen"] = 0.5,
               ["spell-points"] = 0.15, ["sp-regen"] = 0.8, ["damage-*"] = 0.3,
               ["weapon-damage"] = 2.5, ["weapon-accuracy"] = 1.5, ["weapon-crit"] = 1.5 },
  melee    = { strength = 3, agility = 2.5, vitality = 1.5, ar = 3, hp = 0.2, ["hp-regen"] = 0.5, ["damage-*"] = 0.3,
               ["weapon-damage"] = 4, ["weapon-accuracy"] = 2, ["weapon-crit"] = 2, wisdom = 0.3, knowledge = 0.3 },
  caster   = { wisdom = 3, knowledge = 3, intelligence = 3, ["spell-points"] = 0.2, ["sp-regen"] = 1, ar = 2, hp = 0.1,
               vitality = 1, sanity = 1, ["damage-*"] = 0.2 },
  tank     = { ar = 5, hp = 0.3, vitality = 3, ["hp-regen"] = 1, strength = 1.5, agility = 1, ["damage-*"] = 0.1, ["weapon-damage"] = 1 },
  healer   = { wisdom = 3, knowledge = 2, ["spell-points"] = 0.2, ["sp-regen"] = 1.5, vitality = 1.5, ar = 2, hp = 0.15,
               ["hp-regen"] = 0.5, sanity = 1 },
  thief    = { agility = 3.5, strength = 2, vitality = 1, ar = 2, hp = 0.15, ["hp-regen"] = 0.3, ["damage-*"] = 0.3,
               ["weapon-damage"] = 3, ["weapon-accuracy"] = 2.5, ["weapon-crit"] = 3, knowledge = 0.5 },
  paladin  = { strength = 2.5, vitality = 2, ar = 3.5, wisdom = 1.5, hp = 0.2, ["hp-regen"] = 0.5, ["spell-points"] = 0.1,
               ["sp-regen"] = 0.5, ["damage-*"] = 0.2, ["weapon-damage"] = 3, ["weapon-accuracy"] = 1.5, ["weapon-crit"] = 1 },
  balanced = { ["*"] = 1, ar = 2, hp = 0.1, ["spell-points"] = 0.1, ["damage-*"] = 0.2 },
}
-- Materia Magica's classes (help classes), each with the build its description suggests
local CLASS_BUILD = {
  fighter = "melee", warrior = "melee", barbarian = "melee", cavalier = "melee", valkyrie = "tank", paladin = "paladin",
  mage = "caster", wizard = "caster", monk = "monk", ranger = "caster", psionic = "caster",
  cleric = "healer", priest = "healer", druid = "healer", shaman = "healer", witch = "caster",
  thief = "thief", rogue = "thief", bard = "thief", knave = "thief",
}
-- a class Oven has no build for gets its group's: learned from `help classes` (fighter / mage /
-- cleric / thief columns), so classes the game adds later still get something sensible
local GROUP_BUILD = { fighter = "melee", warrior = "melee", mage = "caster", cleric = "healer", thief = "thief" }

function M.classBuild(cls)
  cls = (cls or ""):lower()
  if CLASS_BUILD[cls] then return CLASS_BUILD[cls], true end
  local grp = (M.cfg.classGroups or {})[cls]
  if grp and GROUP_BUILD[grp] then return GROUP_BUILD[grp], true end
  return "balanced", cls == ""
end

-- reading a class's help page: "A Barbarian's primary attribute is STRENGTH."
function M.noteClassPrimary(l)
  local cls, stat = l:match("^%s*An? (%a+)'s primary attribute is (%a+)")
  if not cls then return end
  M.cfg.classPrimary = M.cfg.classPrimary or {}
  M.cfg.classPrimary[cls:lower()] = stat:lower()
  M.saveSettings()
end

-- reading a race's help page: its name ("dwarf - a hardy playable race ..."), its weapon
-- bonuses from the description ("deal 10% more damage with bashing weapons", "strong
-- fighters when equipped with staves"), and the "Maximum racial stats" block
local WEAPON_WORDS = { bashing = "bash", slashing = "slash", piercing = "pierce", blunt = "bash",
  staves = "staff", axes = "axe", swords = "sword", daggers = "dagger", spears = "spear", maces = "mace",
  flails = "flail", hammers = "hammer", bows = "bow", whips = "whip", polearms = "polearm", halberds = "halberd" }
local function weaponWord(w)
  w = w:lower()
  return WEAPON_WORDS[w] or w:gsub("s$", "")
end

function M.parseRaceBonuses(text)
  local out = {}
  text = text:gsub("%s+", " ")
  for pct, kind in text:gmatch("(%d+)%% more damage with (%a+) weapons") do
    out[#out + 1] = { kind = weaponWord(kind), pct = tonumber(pct) }
  end
  for kind in text:gmatch("strong fighters when equipped with (%a+)") do
    out[#out + 1] = { kind = weaponWord(kind), pct = 10, assumed = true }
  end
  for kind in text:gmatch("excel when wielding (%a+)") do
    out[#out + 1] = { kind = weaponWord(kind), pct = 10, assumed = true }
  end
  return out
end

function M.noteRaceHelp(l)
  local race = l:match("^(%a[%a%-]*) %- an? [%a%s%-]-playable race")
  if race then M.raceHelp = { race = race:lower(), text = {} }; return end
  local st = M.raceHelp
  if not st then return end
  if l:match("^Maximum racial stats") then
    st.on = true; st.stats = {}
    M.cfg.raceBonus = M.cfg.raceBonus or {}
    M.cfg.raceBonus[st.race] = M.parseRaceBonuses(table.concat(st.text, " "))
    return
  end
  if not st.on then st.text[#st.text + 1] = l; return end
  if trim(l) == "" or l:match("^Maximum racial vital") then
    M.cfg.raceStats = M.cfg.raceStats or {}
    if next(st.stats) then M.cfg.raceStats[st.race] = st.stats end
    M.saveSettings()
    M.raceHelp = nil
    return
  end
  for key, v in l:gmatch("(%a+):%s+(%d+)") do st.stats[key:lower()] = tonumber(v) end
end

-- the weapon bonuses that apply to you: your race's, unless your build sets weapon:KIND itself
function M.weaponBonuses(w)
  local out, seen = {}, {}
  for k, v in pairs(w or {}) do
    local kind = k:match("^weapon:(.+)$")
    if kind then out[#out + 1] = { kind = kind, pct = v, own = true }; seen[kind] = true end
  end
  local race = ((M.cfg.char or {}).race or ""):lower()
  for _, b in ipairs((M.cfg.raceBonus or {})[race] or {}) do
    if not seen[b.kind] then out[#out + 1] = b end
  end
  return out
end

-- does a weapon count as KIND: its damage type (bash), its noun (Your maul ...) or a keyword
local function weaponIs(it, kind)
  local wp = it.weapon or {}
  if (wp.dmgType or ""):lower() == kind then return true end
  local noun = (wp.summary or ""):match("^Your (%a+) will deal")
  if noun and noun:lower() == kind then return true end
  for word in (it.keywords or ""):lower():gmatch("%S+") do if word == kind then return true end end
  return false
end
M.weaponIs = weaponIs

-- reading `help classes`: "Character classes in Alyria are as follows:", a row of group
-- names, then the classes under each, in columns
function M.noteClassHelp(l)
  local st = M.classHelp
  if not st then
    if l:match("^%s*Character classes in .- are as follows:") then M.classHelp = { stage = 1 } end
    return
  end
  if trim(l) == "" then
    if st.stage == 2 then
      M.classHelp = nil
      M.saveSettings()
    end
    return
  end
  if st.stage == 1 then
    st.cols = {}
    local pos = 1
    while true do
      local a, b, word = l:find("(%u%u+)", pos)
      if not a then break end
      st.cols[#st.cols + 1] = { at = a, group = word:lower() }
      pos = b + 1
    end
    if #st.cols == 0 then M.classHelp = nil; return end
    st.stage = 2
    M.cfg.classGroups = M.cfg.classGroups or {}
    for _, c in ipairs(st.cols) do M.cfg.classGroups[c.group] = c.group end
    return
  end
  -- a row of classes: each belongs to the group whose column it starts nearest
  local pos = 1
  while true do
    local a, b, word = l:find("(%a[%a%-']*)", pos)
    if not a then break end
    local best, bd
    for _, c in ipairs(st.cols) do
      local d = math.abs(c.at - a)
      if not bd or d < bd then best, bd = c, d end
    end
    if best then M.cfg.classGroups[word:lower()] = best.group end
    pos = b + 1
  end
end
local RANK = { min = 1, minimal = 1, low = 2, med = 3, medium = 3, moderate = 3, high = 4, max = 5, maximum = 5 }

function M.classPrimary()
  local cls = ((M.cfg.char or {}).class or ""):lower()
  return cls ~= "" and (M.cfg.classPrimary or {})[cls] or nil
end

function M.activeBuild()
  local name = M.cfg.build
  if not name then name = M.classBuild((M.cfg.char or {}).class) end
  local custom = (M.cfg.builds or {})[name]
  local w = custom or M.buildPresets[name] or M.buildPresets.balanced
  -- a starting build puts your class's primary attribute (from its help page) on top
  local primary = M.classPrimary()
  if not custom and primary then
    local top = 0
    for _, v in pairs(w) do if v > top then top = v end end
    if (w[primary] or 0) < top + 0.5 then
      local copy = {}
      for k, v in pairs(w) do copy[k] = v end
      copy[primary] = top + 0.5
      w = copy
    end
  end
  -- your race's weaknesses (GMCP: "maladapted: disease-res -25"): cover for them is worth more,
  -- 0.1 a point plus 0.02 for each point of weakness, unless your own build sets the stat
  local weak = {}
  for stat, mod in pairs(M.innateMods()) do
    if mod < 0 and not (custom and custom[stat]) then weak[stat] = 0.1 + 0.02 * -mod end
  end
  if next(weak) then
    local copy = {}
    for k, v in pairs(w) do copy[k] = v end
    for k, v in pairs(weak) do copy[k] = math.max(copy[k] or 0, v) end
    w = copy
  end
  return name, w
end

local function weightOf(w, stat)
  if w[stat] then return w[stat] end
  local best, bestLen
  for k, v in pairs(w) do
    if k:sub(-1) == "*" and stat:sub(1, #k - 1) == k:sub(1, -2) and (not bestLen or #k > bestLen) then best, bestLen = v, #k end
  end
  return best or 0
end

-- an item's stats as { stat = value }: affects, relic affects, AR, and a weapon's ratings
function M.itemStats(it)
  local s = {}
  for _, list in ipairs({ it.affects or {}, it.relicAffects or {} }) do
    for _, a in ipairs(list) do
      local v = tonumber((tostring(a[2] or ""):gsub(",", "")))
      if a[1] and v then s[a[1]] = (s[a[1]] or 0) + v end
    end
  end
  if tonumber(it.ar) then s.ar = (s.ar or 0) + tonumber(it.ar) end
  local wp = it.weapon
  if wp then
    local function r(x) return RANK[tostring(x or ""):lower()] end
    if r(wp.dmgLevel) then s["weapon-damage"] = r(wp.dmgLevel) end
    if r(wp.accuracy) then s["weapon-accuracy"] = r(wp.accuracy) end
    if r(wp.critChance) then s["weapon-crit"] = r(wp.critChance) end
  end
  return s
end

-- a stat already at its maximum (score's "12/20") gains little from gear: it counts a quarter
local CAPPED = 0.25
function M.statCapped(stat)
  local st = ((M.cfg.char or {}).stats or {})[stat]
  return st and st.cur and st.max and st.cur >= st.max
end

-- each stat's part of an item's gear score: { stat, value, weight, capped, boost, points }
function M.scoreParts(it, w)
  if not it then return nil end
  if not w then local _; _, w = M.activeBuild() end
  local boost = 1
  if it.weapon then
    for _, b in ipairs(M.weaponBonuses(w)) do
      if M.weaponIs(it, b.kind) then boost = boost + (tonumber(b.pct) or 0) / 100 end
    end
  end
  local parts = {}
  for stat, v in pairs(M.itemStats(it)) do
    local capped = M.statCapped(stat) and true or false
    local wt = weightOf(w, stat)
    local b = stat:match("^weapon%-") and boost or 1
    parts[#parts + 1] = { stat = stat, value = v, weight = wt, capped = capped, boost = b,
                          points = v * wt * (capped and CAPPED or 1) * b }
  end
  table.sort(parts, function(x, y)
    if math.abs(x.points) ~= math.abs(y.points) then return math.abs(x.points) > math.abs(y.points) end
    return x.stat < y.stat
  end)
  return parts
end

function M.gearScore(it, w)
  if not it then return nil end
  local total = 0
  for _, p in ipairs(M.scoreParts(it, w)) do total = total + p.points end
  return math.floor(total * 10 + 0.5) / 10
end

-- what you wear in the same place as `it` (by its "worn" text); with two of a kind (rings,
-- wrists, necks) the weaker one, since that's the one a new item would replace
function M.wornLike(it, w)
  if not it or not it.worn then return nil end
  local worst, ws
  for _, n in ipairs(M.eqNames or {}) do
    local e = M.items[n]
    if e and e.worn == it.worn and e.name ~= it.name then
      local s = M.gearScore(e, w) or 0
      if not ws or s < ws then worst, ws = e, s end
    end
  end
  return worst
end

-- "Gear score 23.5 (monk) · you wear a dwarven girdle: 18.0 → +5.5 (+31%)"
function M.scoreLine(it)
  local bname, w = M.activeBuild()
  local sc = M.gearScore(it, w)
  if not sc then return nil end
  local segs = { { C.key, "Gear score " }, { C.num, tostring(sc) }, { C.dim, "  (" .. bname .. " build)" } }
  local worn = M.wornLike(it, w)
  local wearing = false
  for _, n in ipairs(M.eqNames or {}) do if n == it.name then wearing = true end end
  if wearing then
    segs[#segs + 1] = { C.dim, "  ·  you're wearing it" }
  elseif worn then
    local ws = M.gearScore(worn, w)
    local d = math.floor((sc - ws) * 10 + 0.5) / 10
    local pct = ws ~= 0 and string.format(" (%+d%%)", math.floor((sc - ws) / math.abs(ws) * 100 + 0.5)) or ""
    segs[#segs + 1] = { C.dim, "  ·  you wear " .. worn.name .. ": " .. ws .. " → " }
    segs[#segs + 1] = { d > 0 and C.plus or (d < 0 and C.minus or C.dim),
                        (d > 0 and "+" or "") .. d .. pct .. (d > 0 and " upgrade" or (d < 0 and " worse" or " same")) }
  end
  return segs
end

-- sbo upgrades: for each place you wear something, the best item Oven knows for it
-- What you carry: the last inventory list, and the last look inside each container. Kept between
-- sessions; a container's contents only count while the container is in your inventory.
function M.updateCarried(cap)
  if cap.kind ~= "contents" then return end
  local names = M.listNames(cap.plain)
  local first = trim(cap.plain[1] or "")
  local c = M.cfg.carried or { inv = {}, bags = {} }
  M.cfg.carried = c
  local isInv = cap.target == "inventory"
  for _, l in ipairs(cap.plain) do if trim(l):match("^You are carrying:?$") then isInv = true end end
  if isInv then
    c.inv, c.at = names, os.time()
  else
    local bag
    for _, l in ipairs(cap.plain) do
      bag = trim(l):match("^(.-) contains:?$")
      if bag then break end
    end
    if not bag then return end
    c.bags[bag:lower()] = names
  end
  M.saveSettings()
end

-- name -> "" (carried) or the container it's in
function M.carriedItems()
  local c = M.cfg.carried
  if not c or not c.at then return nil end
  local out = {}
  for _, n in ipairs(c.inv or {}) do out[n] = "" end
  for _, n in ipairs(c.inv or {}) do
    for _, x in ipairs((c.bags or {})[n:lower()] or {}) do if out[x] == nil then out[x] = n end end
  end
  return out
end

function M.upgradeLines(width, all)
  local bname, w = M.activeBuild()
  local lvl = tonumber((M.cfg.char or {}).total or (M.cfg.char or {}).level)
  local out = { header("gear", "", width, "Upgrades  (" .. bname .. " build" .. (all and ", everything seen" or "") .. ")") }
  local carried = not all and M.carriedItems() or nil
  if not all and not carried then
    out[#out + 1] = { { C.dim, "type i (and look in your bags) so Oven knows what you carry - or sbo upgrades all for everything you've seen" } }
    return out
  end
  local byWorn = {}
  for _, r in ipairs(M.dbRows("SELECT name, worn, level FROM items WHERE worn IS NOT NULL AND worn != ''")) do
    byWorn[r.worn] = byWorn[r.worn] or {}
    table.insert(byWorn[r.worn], r)
  end
  local wearing, isWorn = {}, {}
  for _, n in ipairs(M.eqNames or {}) do
    isWorn[n] = true
    local it = M.items[n]
    if it and it.worn then wearing[#wearing + 1] = it end
  end
  -- two of a kind: only the weaker one is up for replacing
  local weakest = {}
  for _, it in ipairs(wearing) do
    local s = M.gearScore(it, w) or 0
    if not weakest[it.worn] or s < weakest[it.worn].s then weakest[it.worn] = { it = it, s = s } end
  end
  if #wearing == 0 then out[#out + 1] = { { C.dim, "type eq and look at your gear first (sbo eq learn does it in one go)" } }; return out end
  local shown = 0
  local links = {}
  M.lastUpgrades = {}
  for _, cur in ipairs(wearing) do
   if weakest[cur.worn] and weakest[cur.worn].it == cur then
    local cs = M.gearScore(cur, w)
    local best, bs
    for _, r in ipairs(byWorn[cur.worn] or {}) do
      local tooHigh = lvl and tonumber(r.level) and tonumber(r.level) > lvl
      if not isWorn[r.name] and not tooHigh and (all or carried[r.name]) then
        local s = M.gearScore(M.items[r.name], w)
        if s and s > cs and (not bs or s > bs) then best, bs = r.name, s end
      end
    end
    if best then
      shown = shown + 1
      local bestIt = M.items[best]
      M.lastUpgrades[shown] = { cur = cur.name, best = best }
      out[#out + 1] = { { C.dim, string.format("%2d ", shown) }, { C.slot, pad(cur.worn, 21) }, { C.item, cur.name }, { C.dim, "  " .. cs } }
      local row = { { C.dim, pad("", 24) .. "→ " }, { C.item, best }, { C.plus, "  " .. bs .. string.format("  (+%s)", math.floor((bs - cs) * 10 + 0.5) / 10) } }
      local where = carried and carried[best]
      if where and where ~= "" then row[#row + 1] = { C.dim, "  in " .. where } end
      out[#out + 1] = row
      -- why: the stats that make the difference, from the score breakdown
      local why = M.upgradeWhy(cur, bestIt, w)
      if #why > 0 then
        local r = { { C.dim, pad("", 26) } }
        for k, x in ipairs(why) do
          if k > 1 then r[#r + 1] = { C.dim, " · " } end
          r[#r + 1] = { x.d > 0 and C.plus or C.minus, x.text }
        end
        out[#out + 1] = r
      end
      local n, a, z = shown, cur.name, best
      links[#links + 1] = { string.format("%d. compare %s → %s", n, a, z), function() M.compareNames(a, z) end }
    end
   end
  end
  if shown == 0 then
    out[#out + 1] = { { C.dim, all and "nothing Oven has seen beats what you wear (for this build, at your level)"
      or "nothing you carry beats what you wear (for this build, at your level)" } }
  end
  out[#out + 1] = {}
  if all then
    out[#out + 1] = { { C.dim, "everything you've looked at, anywhere · sbo upgrades for only what you carry" } }
  else
    out[#out + 1] = { { C.dim, "what you carry (as of your last i" .. (M.cfg.carried.at and (", " .. M.shortDur(os.time() - M.cfg.carried.at) .. " ago") or "")
      .. ") and have looked at · sbo upgrades all for everything you've seen · sbo eq learn carried" } }
  end
  if shown > 0 then
    out[#out + 1] = { { C.dim, "click one below (or sbo upgrades <number>) for the full comparison" } }
  end
  return out, links
end

-- the few stats that make the difference between what you wear and an upgrade: "+6 ar"
function M.upgradeWhy(cur, best, w)
  local pa, pb = M.scoreParts(cur, w) or {}, M.scoreParts(best, w) or {}
  local d = {}
  for _, p in ipairs(pa) do d[p.stat] = (d[p.stat] or 0) - p.points end
  for _, p in ipairs(pb) do d[p.stat] = (d[p.stat] or 0) + p.points end
  local list = {}
  for st, v in pairs(d) do if math.abs(v) >= 0.05 then list[#list + 1] = { stat = st, d = v } end end
  table.sort(list, function(x, y) if math.abs(x.d) ~= math.abs(y.d) then return math.abs(x.d) > math.abs(y.d) end return x.stat < y.stat end)
  local out = {}
  for i = 1, math.min(3, #list) do
    local x = list[i]
    local r = math.floor(x.d * 10 + 0.5) / 10
    if r == math.floor(r) then r = math.floor(r) end
    x.text = (x.d > 0 and "+" or "−") .. tostring(math.abs(r)) .. " " .. x.stat
    out[#out + 1] = x
  end
  return out
end

function M.buildLines(width)
  local bname, w = M.activeBuild()
  local c = M.cfg.char or {}
  local out = { header("gear", "", width, "Build: " .. bname) }
  out[#out + 1] = { { C.dim, "character: " .. (c.race or "?") .. " " .. (c.class or "?") .. (c.total and (", total level " .. c.total) or "")
    .. (M.cfg.build and "" or "  ·  build picked from your class") } }
  local _, known = M.classBuild(c.class)
  if not M.cfg.build and not c.class then
    out[#out + 1] = { { C.flag, "type score once so Oven knows your class - until then this is the balanced build" } }
  elseif not M.cfg.build and not known then
    out[#out + 1] = { { C.flag, "Oven doesn't know the class '" .. c.class .. "' - using balanced. Pick one: sbo eq build melee / caster / healer / thief / tank (or help classes, and Oven learns it)" } }
  end
  out[#out + 1] = {}
  local keys = {}
  for k in pairs(w) do if not k:match("^weapon:") then keys[#keys + 1] = k end end
  table.sort(keys, function(a, b) if w[a] ~= w[b] then return w[a] > w[b] end return a < b end)
  local stats = c.stats or {}
  local race = (M.cfg.raceStats or {})[(c.race or ""):lower()]
  local primary = M.classPrimary()
  if primary then
    out[#out + 1] = { { C.dim, "primary attribute for " .. c.class .. " (its help page): " }, { C.slot, primary },
      { C.dim, (M.cfg.builds or {})[bname] and "  (your own weights are kept as you set them)" or "  - weighted highest" } }
  elseif c.class then
    out[#out + 1] = { { C.dim, "help " .. c.class:lower() .. " once and Oven puts your class's primary attribute on top" } }
  end
  if next(stats) then out[#out + 1] = { { C.dim, "  " .. pad("stat", 20) .. pad("weight", 9) .. "you now" .. (race and "   race max" or "") } } end
  for _, k in ipairs(keys) do
    local r = { { C.key, "  " .. pad(k, 20) }, { w[k] > 0 and C.num or C.dim, pad(tostring(w[k]), 9) } }
    local st = stats[k]
    if st then
      r[#r + 1] = { M.statCapped(k) and C.flag or C.text, pad(tostring(st.cur or "?") .. "/" .. tostring(st.max or "?"), 7) }
      if race and race[k] then r[#r + 1] = { C.dim, "   " .. race[k] } end
      if M.statCapped(k) then r[#r + 1] = { C.flag, "   at max: gear counts 1/4" } end
    end
    out[#out + 1] = r
  end
  if not next(stats) then out[#out + 1] = { { C.dim, "  (type score so Oven can see which stats are at their maximum)" } } end
  local bon = M.weaponBonuses(w)
  if #bon > 0 then
    out[#out + 1] = {}
    for _, b in ipairs(bon) do
      out[#out + 1] = { { C.key, "  weapon bonus  " }, { C.plus, string.format("+%s%% ", b.pct) }, { C.text, b.kind .. " weapons" },
        { C.dim, b.own and "  (your setting)" or (b.assumed and "  (your race's page names no number - assumed; sbo eq build set weapon:" .. b.kind .. " N)" or "  (your race's page)") } }
    end
  end
  local innate = M.innateMods()
  if next(innate) then
    out[#out + 1] = {}
    local keys = {}
    for k in pairs(innate) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = innate[k]
      out[#out + 1] = { { C.key, "  racial        " }, { v < 0 and C.minus or C.plus, string.format("%+d ", v) }, { C.text, k },
        { C.dim, v < 0 and string.format("  (a weakness: %s on gear counts %.1f)", k, weightOf(w, k)) or "" } }
    end
  end
  if race then
    local fav = {}
    for k, v in pairs(race) do if v > 17 then fav[#fav + 1] = k .. " " .. v end end
    table.sort(fav)
    if #fav > 0 then out[#out + 1] = {}; out[#out + 1] = { { C.dim, "your race's strengths (average max is 17): " .. table.concat(fav, ", ") } } end
  end
  out[#out + 1] = {}
  local names = {}
  for n in pairs(M.buildPresets) do names[n] = true end
  for n in pairs(M.cfg.builds or {}) do names[n] = true end
  local list = {}
  for n in pairs(names) do list[#list + 1] = n end
  table.sort(list)
  out[#out + 1] = { { C.dim, "builds: " .. table.concat(list, ", ") } }
  out[#out + 1] = { { C.dim, "sbo eq build NAME switches (or makes a new one) · sbo eq build set STAT WEIGHT · sbo eq build reset" } }
  return out
end

function M.buildCommand(b)
  b = trim(b or "")
  local w = M.cfg.window and M.viewCols() or columns("main")
  local function show(lines) M.viewOut(lines) end
  if b == "" then return show(M.buildLines(w)) end
  local stat, val = b:match("^set%s+(%S+)%s+(%-?[%d%.]+)$")
  if stat then
    local name, cur = M.activeBuild()
    local copy = {}
    for k, v in pairs(cur) do copy[k] = v end
    copy[stat:lower()] = tonumber(val)
    M.cfg.builds = M.cfg.builds or {}
    M.cfg.builds[name] = copy
    M.cfg.build = name
    M.saveSettings()
    return M.say(string.format("%s build: %s now counts %s per point", name, stat:lower(), val))
  end
  if b == "reset" then
    local name = M.activeBuild()
    if M.cfg.builds then M.cfg.builds[name] = nil end
    if not M.buildPresets[name] then M.cfg.build = nil end
    M.saveSettings()
    return M.say("build " .. name .. (M.buildPresets[name] and " back to its starting weights" or " removed"))
  end
  if b == "auto" then M.cfg.build = nil; M.saveSettings(); return M.say("build follows your class again: " .. (M.activeBuild())) end
  local name = b:lower()
  if not M.buildPresets[name] and not (M.cfg.builds or {})[name] then
    -- a new build, starting from the current one
    local _, cur = M.activeBuild()
    local copy = {}
    for k, v in pairs(cur) do copy[k] = v end
    M.cfg.builds = M.cfg.builds or {}
    M.cfg.builds[name] = copy
    M.say("new build '" .. name .. "', starting from your current weights - sbo eq build set STAT WEIGHT to shape it")
  else
    M.say("using the " .. name .. " build")
  end
  M.cfg.build = name
  M.saveSettings()
end

function M.compareLines(a, b, width)
  local out = {}
  local cw = math.max(8, math.min(20, math.floor((width - 16 - 10) / 2)))
  local function cut(s, n) s = tostring(s); n = n or cw; return ulen(s) > n and (s:sub(1, n - 1) .. "…") or s end
  out[#out + 1] = { { C.rule, "── " }, { C.title, "Compare " }, { C.rule, string.rep("─", math.max(2, width - 12)) } }
  out[#out + 1] = { { C.dim, " A  " }, { C.item, a.name } }
  out[#out + 1] = { { C.dim, " B  " }, { C.item, b.name } }
  out[#out + 1] = { { C.dim, pad("", 16) .. pad("A", cw + 2) .. pad("B", cw + 2) .. "B vs A" } }
  local rows = M.compareRows(a, b)
  local okS, sa = pcall(M.gearScore, a)
  local okB, sb = pcall(M.gearScore, b)
  if okS and okB and sa and sb then
    local d = math.floor((sb - sa) * 10 + 0.5) / 10
    table.insert(rows, 1, { "Gear score", tostring(sa), tostring(sb), d == 0 and "=" or ((d > 0 and "+" or "") .. d), d })
  end
  for _, r in ipairs(rows) do
    local dcol = r[5] > 0 and C.plus or (r[5] < 0 and C.minus or C.dim)
    local acol = r[5] < 0 and C.plus or C.item
    local bcol = r[5] > 0 and C.plus or C.item
    out[#out + 1] = { { C.key, pad(cut(r[1], 15), 16) }, { acol, pad(cut(r[2]), cw + 2) },
                      { bcol, pad(cut(r[3]), cw + 2) }, { dcol, r[4] } }
  end
  pcall(M.scoreBreakdown, out, a, b, cw, cut)
  return out
end

-- under a comparison: where each item's gear score comes from, stat by stat
-- ("strength   9  +3×3     15  +5×3     +6")
local function num1(x)
  local r = math.floor(x * 10 + 0.5) / 10
  return (r == math.floor(r)) and tostring(math.floor(r)) or tostring(r)
end
function M.scoreBreakdown(out, a, b, cw, cut)
  local bname, w = M.activeBuild()
  local pa, pb = M.scoreParts(a, w), M.scoreParts(b, w)
  if not pa or not pb or (#pa == 0 and #pb == 0) then return end
  local byA, byB, order, seen = {}, {}, {}, {}
  for _, p in ipairs(pa) do byA[p.stat] = p end
  for _, p in ipairs(pb) do byB[p.stat] = p end
  -- biggest difference first
  for _, p in ipairs(pa) do if not seen[p.stat] then seen[p.stat] = true; order[#order + 1] = p.stat end end
  for _, p in ipairs(pb) do if not seen[p.stat] then seen[p.stat] = true; order[#order + 1] = p.stat end end
  local function pts(p) return p and p.points or 0 end
  table.sort(order, function(x, y)
    local dx, dy = math.abs(pts(byB[x]) - pts(byA[x])), math.abs(pts(byB[y]) - pts(byA[y]))
    if dx ~= dy then return dx > dy end
    return x < y
  end)
  local anyCap, anyBoost = false, false
  local function cell(p)
    if not p then return "-" end
    local how = string.format("%+d", p.value):gsub("^%+%-", "-") .. "×" .. num1(p.weight)
    if p.capped then how = how .. "¼"; anyCap = true end
    if p.boost ~= 1 then how = how .. "↑"; anyBoost = true end
    return num1(p.points) .. "  " .. how
  end
  out[#out + 1] = {}
  out[#out + 1] = { { C.key, "Score breakdown" }, { C.dim, "  (" .. bname .. " build)  points = value × weight" } }
  for _, st in ipairs(order) do
    local x, y = byA[st], byB[st]
    local d = pts(y) - pts(x)
    if pts(x) ~= 0 or pts(y) ~= 0 then
      local dcol = d > 0.05 and C.plus or (d < -0.05 and C.minus or C.dim)
      out[#out + 1] = { { C.slot, pad(cut(st, 15), 16) }, { x and C.num or C.dim, pad(cut(cell(x)), cw + 2) },
                        { y and C.num or C.dim, pad(cut(cell(y)), cw + 2) },
                        { dcol, math.abs(d) < 0.05 and "=" or ((d > 0 and "+" or "") .. num1(d)) } }
    end
  end
  local notes = {}
  if anyCap then notes[#notes + 1] = "¼ = already at your maximum, counts a quarter" end
  if anyBoost then notes[#notes + 1] = "↑ = your race's bonus with this kind of weapon" end
  notes[#notes + 1] = "stats your build doesn't weigh count 0 · sbo eq build to see or change the weights"
  out[#out + 1] = { { C.dim, table.concat(notes, " · ") } }
end


-- entry: when given, the comparison is added to that Inspector page
function M.compare(a, b, entry)
  if not a or not b then return false end
  if entry then
    entry.lines[#entry.lines + 1] = {}
    addAll(entry.lines, M.compareLines(a, b, M.viewCols()))
  elseif M.cfg.window then
    M.viewOut(M.compareLines(a, b, M.viewCols()))
  else
    render("main", M.compareLines(a, b, columns("main")))
  end
  return true
end

-- clickable actions under an item in the viewer
-- clickable actions under an item in the Inspector
local function itemLinks(entry, it)
  local name = it.name
  entry.links[#entry.links + 1] = { "pin for comparing  (compare the next items you look at against this one)",
    function() M.pin(name) end }
  local prev = M.recent[#M.recent - 1]
  if prev then
    entry.links[#entry.links + 1] = { "compare with " .. prev, function() M.compareNames(prev, name) end }
  end
end

function M.pin(name)
  local it = M.findItem(name or M.recent[#M.recent])
  if not it then return M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> no remembered item matches that") end
  M.pinned = it.name; M.saveItems()
  M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> pinned: " .. it.name .. " - items you look at next are compared against it (sbo eq compare against to stop)")
end

function M.compareNames(qa, qb)
  local a, b = M.findItem(qa), M.findItem(qb)
  if not a then return M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> no remembered item matches: " .. tostring(qa)) end
  if not b then return M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> no remembered item matches: " .. tostring(qb)) end
  M.compare(a, b)
end

-- after an item look: remember it, offer links, auto-compare
function M.afterItem(raw, entry)
  local ok, it = pcall(M.parseItem, raw)
  if not ok or not it or not it.name then return end
  M.remember(it)
  it = M.items[it.name]
  if entry and it.worn then
    local okS, segs = pcall(M.scoreLine, it)
    if okS and segs then entry.lines[#entry.lines + 1] = {}; entry.lines[#entry.lines + 1] = segs end
  end
  if entry then itemLinks(entry, it) end
  local done = {}
  if M.pinned and M.pinned ~= it.name and M.items[M.pinned] then
    M.compare(M.items[M.pinned], it, entry); done[M.pinned] = true
  end
  if M.cfg.autocompare and it.worn then
    local worn = {}
    for _, n in ipairs(M.eqNames) do worn[n] = true end
    if not worn[it.name] then
      for n in pairs(worn) do
        local e = M.items[n]
        if e and not done[n] and e.worn == it.worn then M.compare(e, it, entry); done[n] = true end
      end
    end
  end
end

---------------------------------------------------------------------------
-- Prompt bar: the game's prompt shown in a fixed bar under the main window
---------------------------------------------------------------------------
function M.barFontSize()
  if (M.cfg.barFont or 0) > 0 then return M.cfg.barFont end
  local ok, sz = pcall(getFontSize, "main")
  return (ok and tonumber(sz)) or 12
end

function M.barHeight()
  local ok, _, h = pcall(calcFontSize, M.barFontSize())
  h = (ok and tonumber(h)) or 16
  return math.ceil(h * 1.2) * M.cfg.barLines + 6
end

function M.layoutBar()
  if not M.bar or not M.cfg.bar then return end
  local W, H = getMainWindowSize()
  local left, right = 0, 0
  local ok, b = pcall(getBorderSizes)
  if ok and type(b) == "table" then left, right = b.left or 0, b.right or 0
  else
    local okR, r = pcall(getBorderRight); if okR and r then right = r end
    local okL, l = pcall(getBorderLeft); if okL and l then left = l end
  end
  local h = M.barHeight()
  local sessionOn = M.cfg.barSession and M.sbar and not M.barCollapsed
  local atTop = sessionOn and M.cfg.barSessionPos ~= "bottom"
  local below = sessionOn and not atTop
  local barY = H - (below and (h * 2) or h)
  -- while you fight (combat mode mxp): your targets' line sits right above the prompt bar
  local combatOn = M.cbar and M.cbarShown
  local total = H - barY + (combatOn and h or 0)
  setBorderBottom(total)
  M.bar:move(left, barY)
  M.bar:resize(W - left - right, h)
  if combatOn then
    M.cbar:show(); M.cbar:move(left, barY - h); M.cbar:resize(W - left - right, h)
  elseif M.cbar then
    M.cbar:hide()
  end
  -- the top line takes space above any top border something else already uses, and gives it back after
  if atTop then
    if not M.topTaken then
      local okT, t = pcall(getBorderTop)
      M.baseTop = (okT and tonumber(t)) or 0
      M.topTaken = true
    end
    setBorderTop(M.baseTop + h)
    pcall(M.layoutQuestHud)
  elseif M.topTaken then
    setBorderTop(M.baseTop or 0)
    M.topTaken = nil
  end
  if sessionOn then
    M.sbar:show()
    M.sbar:move(left, atTop and (M.baseTop or 0) or (H - h))
    M.sbar:resize(W - left - right, h)
  elseif M.sbar then
    M.sbar:hide()
  end
  M.barRight = right
end

-- the optional session line under the prompt bar
function M.showSessionBar(on)
  if on and M.cfg.bar then
    if not M.sbar then
      M.sbar = Geyser.Label:new({ name = "ovenSessionBarLabel", x = 0, y = 0, width = 200, height = 20 })
    end
    M.sbar:show()
    M.applyBarBg()
    if M.sessTimer then killTimer(M.sessTimer) end
    M.sessTimer = tempTimer(30, function() pcall(M.drawBar) end, true)   -- keep the clock moving
  else
    if M.sbar then M.sbar:hide() end
    if M.sessTimer then killTimer(M.sessTimer); M.sessTimer = nil end
  end
  M.layoutBar()
  pcall(M.drawBar)
end

function M.showBar(on)
  if on then
    if M.bar and not M.bar.rawEcho then
      -- the console-based bar of versions before 0.10.12
      pcall(function() M.bar:hide() end); M.bar = nil
    end
    if not M.bar then
      -- a label: unlike a console it can centre its text vertically
      M.bar = Geyser.Label:new({ name = "ovenPromptBarLabel", x = 0, y = 0, width = 200, height = 20 })
    end
    M.bar:show()
    -- clicking the version tag at the right end checks for / installs an update
    pcall(function() M.bar:setClickCallback(function(ev) M.barClick(ev) end) end)
    M.layoutBar()
    M.applyBarBg()
    M.drawBar()
    if M.cfg.barSession then M.showSessionBar(true) end
  else
    if M.bar then M.bar:hide() end
    if M.sbar then M.sbar:hide() end
    if M.sessTimer then killTimer(M.sessTimer); M.sessTimer = nil end
    if M.topTaken then setBorderTop(M.baseTop or 0); M.topTaken = nil end
    setBorderBottom(0)
  end
end

local promptLogged = false
-- "[Library][SAFE]<180hp 325sp 296st>" -> {tags={...}, vals={{"hp",180},...}, rest="..."}
function M.parsePrompt(t)
  local p = { tags = {}, vals = {} }
  -- in a group: "([97%]Roarke)" - whoever in the group is lowest on health
  local gpct, gname = t:match("%(%[(%d+)%%%]%s*(.-)%)")
  if gpct then
    p.group = { name = trim(gname), pct = tonumber(gpct) }
    t = t:gsub("%(%[%d+%%%].-%)", "", 1)
  end
  for tag in t:gmatch("%[([^%]]+)%]") do p.tags[#p.tags + 1] = tag end
  local inner = t:match("<(.-)>")
  if inner then
    for n, k in inner:gmatch("(%-?%d+)(%a+)") do p.vals[#p.vals + 1] = { k:lower(), tonumber(n) } end
  end
  p.rest = trim(t:gsub("%[[^%]]*%]", ""):gsub("<.->", ""))
  return p
end

-- maxima, level and exp-to-level come from `score` (and live from MSDP when the game sends it)
-- Session: exp / kills since you logged in, and how fast levels are coming
M.sess = M.sess or { start = os.time(), gained = 0 }
function M.sessionScore(sc)
  local S = M.sess
  local exp = sc.exp and tonumber((sc.exp:gsub(",", "")))
  local kills = sc.mobKills and tonumber((sc.mobKills:gsub(",", "")))
  local deaths = sc.mobDeaths and tonumber((sc.mobDeaths:gsub(",", "")))
  if exp then
    if not S.exp0 then S.exp0, S.t0 = exp, os.time() end
    S.expNow, S.tNow = exp, os.time()
  end
  if kills and not S.kills0 then S.kills0, S.deaths0 = kills, deaths end
  S.killsNow, S.deathsNow = kills or S.killsNow, deaths or S.deathsNow
  if deaths then S.deathsLive = 0 end   -- score's total now includes them
  if kills then S.killsLive = 0 end
end

-- exp per hour this session, or nil if there isn't enough to go on yet
function M.expRate()
  local S = M.sess
  local gained, since
  if S.exp0 and S.expNow and S.expNow > S.exp0 then
    gained, since = S.expNow - S.exp0 + (S.gainedAfterScore or 0), os.time() - S.t0
  elseif (S.gained or 0) > 0 then
    gained, since = S.gained, os.time() - S.start
  end
  if gained and since and since >= 120 then return gained * 3600 / since end
end

local function duration(sec)
  sec = math.floor(sec)
  local fl = math.floor
  if sec >= 86400 then return string.format("%dd %dh", fl(sec / 86400), fl((sec % 86400) / 3600)) end
  if sec >= 3600 then return string.format("%dh %02dm", fl(sec / 3600), fl((sec % 3600) / 60)) end
  return string.format("%dm", math.max(1, fl(sec / 60)))
end
M.duration = duration

-- live exp gains: the exact message isn't known yet, so lines mentioning experience are
-- logged (kind=observe) for tuning, and a few likely wordings are recognised
M.expGain = { "^You receive ([%d,]+) experience", "^You gain ([%d,]+) experience", "^You have gained ([%d,]+) experience",
              "awarding you .-([%d,]+) experience points",   -- quest rewards: "...awarding you 19 quest points, 6,640 experience points, ..."
              "([%d,]+) experience points?[%.!]" }
local observed = {}
function M.observe(l)
  if not l:find("xperience", 1, true) then return end
  local t = trim(l)
  if M.cfg.samples and not observed[t] and #observed < 100 then
    observed[t] = true; observed[#observed + 1] = t
    local f = io.open(M.samplesFile, "a")
    if f then f:write("===== " .. os.date("%Y-%m-%d %H:%M:%S") .. " | kind=observe | cmd=\n" .. t .. "\n===== end\n\n"); f:close() end
  end
  if M.cap and M.cap.kind == "score" then return end   -- score's own exp line
  for _, p in ipairs(M.expGain) do
    local n = t:match(p)
    if n and not t:find("need", 1, true) then
      n = tonumber((n:gsub(",", "")))
      if n and n > 0 then
        -- kills give "You receive 2,704 experience points."; other exp says "You gain ..."
        M.sess.gained = (M.sess.gained or 0) + n
        if M.sess.exp0 then M.sess.gainedAfterScore = (M.sess.gainedAfterScore or 0) + n end
        local c = M.cfg.char or {}
        if c.tnl then c.tnl = math.max(0, c.tnl - n) end
        if c.exp then c.exp = c.exp + n end
        M.drawBar()
      end
      return
    end
  end
end

-- `sbo log session`: a summary page in the Inspector
function M.sessionLines(width)
  local S, c = M.sess, M.cfg.char or {}
  local out = { header("session", "", width, "Session  (" .. duration(os.time() - S.start) .. ")") }
  local gained = (S.exp0 and S.expNow) and (S.expNow - S.exp0 + (S.gainedAfterScore or 0)) or S.gained or 0
  local rate = M.expRate()
  local cells = {}
  cells[#cells + 1] = { "Exp gained", { { C.plus, M.commaNum(gained) } } }
  cells[#cells + 1] = { "Exp / hour", rate and { { C.num, M.commaNum(math.floor(rate)) } } or { { C.dim, "not enough data yet" } } }
  if c.tnl then cells[#cells + 1] = { "To level " .. ((c.level or 0) + 1), { { C.num, M.commaNum(c.tnl) } } } end
  if c.tnl and rate and rate > 0 then
    cells[#cells + 1] = { "Level in", { { C.title, "≈ " .. duration(c.tnl * 3600 / rate) } } }
  end
  if S.kills0 and S.killsNow then
    cells[#cells + 1] = { "Kills", { { C.plus, tostring(S.killsNow - S.kills0) } } }
    cells[#cells + 1] = { "Deaths", { { C.minus, tostring((S.deathsNow or 0) - (S.deaths0 or 0)) } } }
    local k = S.killsNow - S.kills0
    if k > 0 and gained > 0 and c.tnl then
      cells[#cells + 1] = { "Kills to level", { { C.num, "≈ " .. math.ceil(c.tnl / (gained / k)) } } }
    end
  end
  grid(out, cells, width)
  blank(out)
  if not S.exp0 then
    out[#out + 1] = { { C.dim, "Type score (sc) now and again: exp and kills are measured between scores." } }
  else
    out[#out + 1] = { { C.dim, "Measured from your score at " .. os.date("%H:%M", S.t0) .. " and the latest one; type score to refresh." } }
  end
  return out
end

function M.updateMaxes(raw)
  M.cfg.maxes = M.cfg.maxes or {}
  local ok, sc = pcall(M.parseScore, raw)
  if ok and sc then
    M.sessionScore(sc)
    M.sess.gainedAfterScore = 0
    M.cfg.char = M.cfg.char or {}
    local c = M.cfg.char
    if sc.info["Class Level"] then c.level = tonumber(sc.info["Class Level"]) end
    if sc.info["Total Level"] then c.total = tonumber(sc.info["Total Level"]) end
    if sc.info["Class"] then c.class = sc.info["Class"] end
    if sc.info["Race"] then c.race = sc.info["Race"] end
    local _, known = M.classBuild(c.class)
    if c.class and not known and not M.cfg.build and not M.classWarned then
      M.classWarned = true
      tempTimer(0.5, function()
        M.say("gear score: Oven doesn't know the class '" .. c.class .. "' yet, so it's using the balanced build - type help classes once, or pick one with sbo eq build")
      end)
    end
    if sc.tnl then c.tnl = tonumber((sc.tnl:gsub(",", ""))); c.exp = tonumber((sc.exp:gsub(",", ""))) end
  end
  for _, l in ipairs(raw) do
    for key, cur, mx in l:gmatch("([%a][%a ]-):%s+(%-?%d+)/(%d+)") do
      local k = trim(key)
      if M.maxNames[k] then M.cfg.maxes[M.maxNames[k]] = tonumber(mx)
      else
        -- Strength 12/20 ...: where each attribute stands, for the gear score's caps
        M.cfg.char = M.cfg.char or {}
        M.cfg.char.stats = M.cfg.char.stats or {}
        M.cfg.char.stats[k:lower()] = { cur = tonumber(cur), max = tonumber(mx) }
      end
    end
  end
  M.saveSettings()
end

local barColors = { hp = "tomato", sp = "light_sky_blue", st = "gold", mt = "sandy_brown" }
-- the bar's background (a slight tint so it stands apart from the game text)
function M.barBg()
  local c = M.cfg.barBg
  if type(c) ~= "table" or #c < 3 then c = M.defaults.barBg end
  return c[1], c[2], c[3]
end
function M.applyBarBg()
  local r, g, b = M.barBg()
  local css = string.format(
    "background-color: rgb(%d,%d,%d); padding-left: 4px; qproperty-alignment: 'AlignVCenter | AlignLeft';", r, g, b)
  if M.bar then M.bar:setStyleSheet(css) end
  if M.sbar then M.sbar:setStyleSheet(css) end
  if M.cbar then M.cbar:setStyleSheet(css) end
end

-- characters across the bar
local function barCols()
  local okF, cw = pcall(calcFontSize, M.barFontSize(), (pcall(getFont) and getFont()) or nil)
  cw = (okF and tonumber(cw)) or 8
  local okW, w = pcall(function() return M.bar:get_width() end)
  return math.max(40, math.floor((((okW and tonumber(w)) or 800) - 10) / cw))
end

-- put decho text in the bar, in the main window's font
local function toHtml(d)
  -- decho2html gives every piece of text a (black) background; drop it so the bar's tint shows
  return (decho2html(d)
    :gsub("background%-color:%s*rgba?%b();?", "")
    :gsub("background:%s*rgba?%b();?", ""))
end

-- d: left part (decho); right: optional part pinned to the right edge
local function barEcho(d, label, right)
  label = label or M.bar
  local font = (pcall(getFont) and getFont()) or "monospace"
  local style = string.format("white-space: pre; font-family: '%s', monospace; font-size: %dpt; color: #c0c0c0;",
    font, M.barFontSize())
  if right then
    label:rawEcho(string.format(
      "<table width=\"100%%\" cellspacing=\"0\" cellpadding=\"0\"><tr>" ..
      "<td style=\"%s\">%s</td><td align=\"right\" style=\"%s padding-right: 6px;\">%s</td></tr></table>",
      style, toHtml(d), style, toHtml(right)))
  else
    label:rawEcho(string.format("<div style=\"%s\">%s</div>", style, toHtml(d)))
  end
end

-- short number: 950, 1.3k, 31k, 1.2M
function M.shortNum(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  local out
  if a < 1000 then out = tostring(math.floor(a))
  elseif a < 10000 then out = string.format("%.1fk", a / 1000):gsub("%.0k", "k")
  elseif a < 1000000 then out = string.format("%dk", math.floor(a / 1000 + 0.5))
  else out = string.format("%.1fM", a / 1000000):gsub("%.0M", "M") end
  return (n < 0 and "-" or "") .. out
end

-- short duration: 54m, 1h12m, 2d3h
function M.shortDur(sec)
  local fl = math.floor
  sec = fl(sec)
  if sec >= 86400 then return string.format("%dd%dh", fl(sec / 86400), fl((sec % 86400) / 3600)) end
  if sec >= 3600 then return string.format("%dh%02dm", fl(sec / 3600), fl((sec % 3600) / 60)) end
  return string.format("%dm", math.max(1, fl(sec / 60)))
end

-- full:  "1h 18m · k/d: 25/1 · 25000 xp/hr"      short: "25000 xp/hr"
function M.sessionSegs()
  local S = M.sess
  local dot = { C.dim, " · " }
  local fl = math.floor
  if M.cfg.barSessionStyle == "short" then
    local rate = M.expRate()
    return { { C.num, rate and tostring(fl(rate)) or "-" }, { C.dim, " xp/hr" } }
  end
  local sec = os.time() - S.start
  local t = sec >= 3600 and string.format("%dh %02dm", fl(sec / 3600), fl((sec % 3600) / 60)) or string.format("%dm", math.max(1, fl(sec / 60)))
  local segs = { { C.num, t } }
  segs[#segs + 1] = dot; segs[#segs + 1] = { C.dim, "k/d: " }
  local deaths = ((S.deathsNow or 0) - (S.deaths0 or 0)) + (S.deathsLive or 0)
  local kills = ((S.killsNow or 0) - (S.kills0 or 0)) + (S.killsLive or 0)
  if S.kills0 or (S.killsLive or 0) > 0 then
    segs[#segs + 1] = { C.plus, tostring(kills) }
  else
    segs[#segs + 1] = { C.dim, "-" }
  end
  segs[#segs + 1] = { C.dim, "/" }
  segs[#segs + 1] = { deaths > 0 and C.minus or C.dim, (S.kills0 or deaths > 0 or kills > 0) and tostring(deaths) or "-" }
  local rate = M.expRate()
  segs[#segs + 1] = dot
  segs[#segs + 1] = { C.num, rate and tostring(fl(rate)) or "-" }
  segs[#segs + 1] = { C.dim, " xp/hr" }
  return segs
end

-- the combat line: each target's health bar, then its name; with one target, how the fight's going
function M.drawCombatBar()
  local fights = {}
  for _, F in pairs(M.fights or {}) do fights[#fights + 1] = F end
  table.sort(fights, function(a, b) return (a.order or 0) < (b.order or 0) end)
  local want = #fights > 0 and M.cfg.combatBar and M.cfg.bar and M.bar ~= nil
  if not want then
    if M.cbarShown then
      -- a moment with the end result before it goes
      if M.cbarHideTimer then killTimer(M.cbarHideTimer) end
      M.cbarHideTimer = tempTimer(3, function()
        M.cbarHideTimer = nil
        if not next(M.fights or {}) and M.cbarShown then M.cbarShown = false; pcall(M.layoutBar) end
      end)
    end
    return
  end
  if M.cbarHideTimer then killTimer(M.cbarHideTimer); M.cbarHideTimer = nil end
  if not M.cbar then
    M.cbar = Geyser.Label:new({ name = "ovenCombatBarLabel", x = 0, y = 0, width = 200, height = 20 })
    M.applyBarBg()
  end
  if not M.cbarShown then M.cbarShown = true; pcall(M.layoutBar) end
  -- the current target (the latest round) in full; the others compressed, lowest health first,
  -- as many as fit, then "+N more"
  local cur = fights[1]
  for _, F in ipairs(fights) do if (F.seq or 0) > (cur.seq or 0) then cur = F end end
  local function col(p) p = tonumber(p) or 0; return p >= 70 and C.plus or (p >= 35 and C.title or C.minus) end
  local pctv = tonumber(cur.lastPct) or 0
  local segs = { { col(pctv), M.pctBar(pctv, 8) }, { col(pctv), string.format(" %3d%%", pctv) }, { C.item, "  " .. cur.name },
    { C.dim, string.format("    you hit %d/%d", cur.hit, cur.hit + cur.miss + cur.parried) },
    { C.dim, string.format("  ·  it hit %d/%d", cur.took, cur.took + cur.missed + cur.defended) } }
  if #fights == 1 then segs[#segs + 1] = { C.dim, string.format("  ·  round %d", cur.rounds) } end
  local others = {}
  for _, F in ipairs(fights) do if F ~= cur then others[#others + 1] = F end end
  table.sort(others, function(a, b) return (tonumber(a.lastPct) or 0) < (tonumber(b.lastPct) or 0) end)
  if #others > 0 then
    local okF, cw = pcall(calcFontSize, M.barFontSize(), (pcall(getFont) and getFont()) or nil)
    cw = (okF and tonumber(cw)) or 8
    local okW, w = pcall(function() return M.cbar:get_width() end)
    local cols = math.max(40, math.floor((((okW and tonumber(w)) or 800) - 10) / cw))
    segs[#segs + 1] = { C.dim, "   │   others: " }
    local used = segLen(segs)
    for i, F in ipairs(others) do
      local txt = F.name .. " " .. (tonumber(F.lastPct) or 0) .. "%"
      local rest = #others - i
      local tail = rest > 0 and ulen(" … +" .. rest .. " more") or 0
      if used + ulen(txt) + 3 + tail > cols and i > 1 then
        segs[#segs + 1] = { C.dim, " … +" .. (#others - i + 1) .. " more" }
        break
      end
      if i > 1 then segs[#segs + 1] = { C.dim, " · " }; used = used + 3 end
      segs[#segs + 1] = { col(F.lastPct), txt }
      used = used + ulen(txt)
    end
  end
  barEcho(M.segsToDecho({ segs })[1], M.cbar)
end

function M.drawSessionBar()
  if not M.sbar or not M.cfg.barSession or not M.cfg.bar or M.barCollapsed then return end
  barEcho(M.segsToDecho({ M.sessionSegs() })[1], M.sbar)
end

-- the prompt as the bar shows it: HP / SP / ST from GMCP (char.vitals, live even between prompts),
-- the rest (mail, group health, anything GMCP doesn't send) from the last prompt
local VITALS = { "hp", "sp", "st" }
function M.barPrompt()
  local p = M.parsePrompt(M.lastPromptText or "")
  local v = M.gmcpGet and M.gmcpGet("char.vitals")
  if type(v) == "table" then
    local have = {}
    for i, x in ipairs(p.vals) do have[x[1]] = i end
    for _, k in ipairs(VITALS) do
      local n = tonumber(v[k])
      if n then
        if have[k] then p.vals[have[k]][2] = n
        else p.vals[#p.vals + 1] = { k, n } end
      end
    end
    -- keep hp, sp, st first and in that order
    table.sort(p.vals, function(a, b)
      local ia, ib = 0, 0
      for i, k in ipairs(VITALS) do if a[1] == k then ia = i end; if b[1] == k then ib = i end end
      return (ia == 0 and 99 or ia) < (ib == 0 and 99 or ib)
    end)
  end
  return p
end

function M.drawBar()
  if not M.bar or not M.bar.rawEcho or not M.lastPromptText then return end
  local p = M.barPrompt()
  if M.cfg.barMode == "raw" or #p.vals == 0 then
    -- drop the game's (black) text background so the bar's tint shows through
    local d = (M.lastPromptDecho or M.lastPromptText):gsub("<(%d+,%d+,%d+):[%d,]+>", "<%1>")
    barEcho(d)
    return
  end
  M.cfg.maxes = M.cfg.maxes or {}
  local segs = {}
  if p.group then
    local g = p.group
    local col = g.pct >= 70 and C.plus or (g.pct >= 35 and C.title or C.minus)
    segs[#segs + 1] = { C.item, g.name ~= "" and (g.name .. " ") or "group " }
    segs[#segs + 1] = { col, g.pct .. "%" }
    segs[#segs + 1] = { C.dim, #p.tags > 0 and " · " or "   " }
  end
  for _, tag in ipairs(p.tags) do
    segs[#segs + 1] = { tag == "SAFE" and C.plus or C.key, tag }
    segs[#segs + 1] = { C.dim, " · " }
  end
  -- the quest with the least time left
  local okS, sQ, _, sLeft = pcall(M.questSoonest)
  if okS and sQ then
    segs[#segs + 1] = { C.dim, "quest " }
    segs[#segs + 1] = { M.timeLeftColor(sLeft), M.shortDur(sLeft) }
    segs[#segs + 1] = { C.dim, " · " }
  end
  if #segs > 0 then segs[#segs] = { C.dim, "   " } end
  -- level and exp to level: prompt > MSDP > last `score`
  local pools, lvl, tnl = {}, nil, nil
  for _, v in ipairs(p.vals) do
    if v[1] == "tnl" or v[1] == "tnx" then tnl = v[2]
    elseif v[1] == "lvl" or v[1] == "lv" or v[1] == "level" then lvl = v[2]
    else pools[#pools + 1] = v end
  end
  if M.mount then pools[#pools + 1] = { "mt", M.mount } end   -- mount stamina, after yours
  local c, live = M.cfg.char or {}, M.live or {}
  lvl = lvl or live.level or c.level
  tnl = tnl or live.tnl or c.tnl
  -- level / tnl go last: HP/SP/ST matter more
  local tail = {}
  if lvl then
    tail[#tail + 1] = { C.title, "L" .. lvl }
    local total = (M.live or {}).total or c.total
    tail[#tail + 1] = { C.dim, " (" .. (total or "-") .. ")" }   -- "-" until score has been seen
  end
  if tnl then
    tail[#tail + 1] = { C.dim, (lvl and "  " or "") .. "tnl " }; tail[#tail + 1] = { C.plus, commaNum(tnl) }
    local info = M.levelInfo()
    if info then tail[#tail + 1] = { C.dim, string.format(" %d%%", math.floor(info.frac * 100)) } end
    local rate = M.expRate()
    if rate and rate > 0 then tail[#tail + 1] = { C.dim, " ≈" .. M.shortDur(tnl * 3600 / rate) } end
  end
  p.vals = pools
  -- gauges are a fixed width (sbo bar width), shrunk only if the bar is too narrow
  local fixed = segLen(segs) + segLen(tail) + ulen(p.rest) + 2
  for _, v in ipairs(p.vals) do
    local mx = M.cfg.maxes[v[1]]
    fixed = fixed + #v[1] + 2 + #(tostring(v[2]) .. "/" .. tostring(mx or v[2])) + 3
  end
  local cols = barCols()
  local room = math.floor((cols - fixed) / math.max(1, #p.vals))
  local gw = math.max(3, math.min(M.cfg.barWidth or 10, room))
  local head = segs
  local function build(gwidth)
    local out = {}
    addAll(out, head)
    for _, v in ipairs(p.vals) do
      local k, cur = v[1], v[2]
      local mx = M.cfg.maxes[k]
      if not mx or cur > mx then mx = cur; M.cfg.maxes[k] = cur end
      out[#out + 1] = { barColors[k] or C.key, k:upper() .. " " }
      addAll(out, M.gauge(cur, mx, gwidth))
      out[#out + 1] = { C.num, " " .. cur }
      out[#out + 1] = { C.dim, "/" .. mx .. "   " }
    end
    addAll(out, tail)
    if p.rest ~= "" then out[#out + 1] = { C.text, "   " .. p.rest } end
    return out
  end
  local main = build(gw)
  -- the session details join this line when they fit (shorter gauges are tried first);
  -- otherwise they get their own line underneath
  local collapsed = false
  if M.cfg.barSession then
    local sess = M.sessionSegs()
    local sep = { C.dim, "   │ " }
    local tagW = ulen(" [v" .. M.version .. " ✓]  ")
    local need = segLen(main) + ulen(sep[2]) + segLen(sess) + tagW - cols
    if need > 0 and #p.vals > 0 then
      local smaller = gw - math.ceil(need / #p.vals)
      if smaller >= 4 then
        main = build(smaller)
        need = segLen(main) + ulen(sep[2]) + segLen(sess) + tagW - cols
      end
    end
    if need <= 0 then
      collapsed = true
      main[#main + 1] = sep
      addAll(main, sess)
    end
  end

  local tag = M.versionTag()
  if collapsed ~= (M.barCollapsed or false) then
    M.barCollapsed = collapsed
    M.layoutBar()
  end
  barEcho(M.segsToDecho({ main })[1], nil, M.segsToDecho({ tag })[1])
  if M.cfg.barSession and not collapsed then pcall(M.drawSessionBar) end
end

-- live level / exp from MSDP, if the game reports them
M.live = M.live or {}
function M.onMsdp(event)
  if type(msdp) ~= "table" then return end
  local L = M.live
  L.level = tonumber(msdp.LEVEL) or L.level
  local tnl = tonumber(msdp.EXPERIENCE_TNL) or tonumber(msdp.EXPERIENCE_TO_LEVEL)
  if not tnl and tonumber(msdp.EXPERIENCE_MAX) and tonumber(msdp.EXPERIENCE) then
    tnl = tonumber(msdp.EXPERIENCE_MAX) - tonumber(msdp.EXPERIENCE)
  end
  L.tnl = tnl or L.tnl
  M.drawBar()
end

---------------------------------------------------------------------------
-- GMCP: what the game reports as data. Where it covers something, it wins over reading text.
---------------------------------------------------------------------------
local function G(path)
  local v = type(gmcp) == "table" and gmcp or nil
  for k in path:gmatch("[^.]+") do
    if type(v) ~= "table" then return nil end
    v = v[k]
  end
  return v
end
M.gmcpGet = G

-- char.status: level, total level and exp to level, as they change
function M.onGmcpStatus()
  local s = G("char.status")
  if type(s) ~= "table" then return end
  local L, c = M.live, M.cfg.char or {}
  M.cfg.char = c
  local lvl, total, tnl = tonumber(s.level), tonumber(s.totallevel), tonumber(s.tnl)
  if lvl then L.level, c.level = lvl, lvl end
  if total then L.total, c.total = total, total end
  if tnl then
    L.tnl, c.tnl = tnl, tnl
  end
  L.enemy = (s.enemy and s.enemy ~= "_empty") and s.enemy or nil
  L.statusAt = os.time()
  L.enemyPct = tonumber(s.enemypct)
  pcall(M.drawBar)
end

-- char.maxstats: HP/SP/ST maximums and each attribute's maximum
local MAXSTAT_POOLS = { maxhp = "hp", maxsp = "sp", maxst = "st" }
function M.onGmcpMaxStats()
  local s = G("char.maxstats")
  if type(s) ~= "table" then return end
  M.cfg.maxes = M.cfg.maxes or {}
  M.cfg.char = M.cfg.char or {}
  local c = M.cfg.char
  c.stats = c.stats or {}
  local changed = false
  for k, v in pairs(s) do
    v = tonumber(v)
    if v then
      local pool = MAXSTAT_POOLS[k]
      if pool then
        if M.cfg.maxes[pool] ~= v then M.cfg.maxes[pool] = v; changed = true end
      else
        local st = c.stats[k] or {}
        if st.max ~= v then st.max = v; c.stats[k] = st; changed = true end
      end
    end
  end
  if changed then M.saveSettings(); pcall(M.drawBar) end
end

-- char.worth: gold, bank, quest points, practices
function M.onGmcpWorth()
  local s = G("char.worth")
  if type(s) ~= "table" then return end
  local w = {}
  for k, v in pairs(s) do w[k] = tonumber(v) or v end
  M.live.worth = w
end

-- char.affect_application_msg: an affect landing on you. Permanent ones (duration -1) are your
-- race's: "maladapted: disease-res -25" - kept, so the gear score can value cover for weaknesses.
function M.onGmcpAffect()
  local a = G("char.affect_application_msg")
  if type(a) ~= "table" or a.target ~= "you" then return end
  if tonumber(a.duration) ~= -1 or not a.modifies or not tonumber(a.modifier) then return end
  M.cfg.char = M.cfg.char or {}
  local c = M.cfg.char
  c.innate = c.innate or {}
  local key = tostring(a.skill or a.modifies) .. "|" .. tostring(a.modifies)
  local mod = tonumber(a.modifier)
  local old = c.innate[key]
  if not old or old.mod ~= mod then
    c.innate[key] = { skill = a.skill, stat = a.modifies, mod = mod }
    M.saveSettings()
  end
end

-- what an innate affect adds up to per stat: { ["disease-res"] = -25 }
function M.innateMods()
  local out = {}
  for _, e in pairs(((M.cfg.char or {}).innate) or {}) do
    if e.stat and e.mod then out[e.stat] = (out[e.stat] or 0) + e.mod end
  end
  return out
end

-- char.lasttargeted: what you're fighting - name, race, mob number, health
function M.onGmcpTarget()
  local t = G("char.lasttargeted")
  if type(t) ~= "table" then return end
  M.live.target = { name = t.short_descr, race = t.race, vnum = tonumber(t.vnum), pct = tonumber(t.hp_percent), at = now() }
end

-- the mob behind "X has been slain!", when it's the one you were fighting
function M.targetFor(name)
  local t = M.live.target
  if not t or not t.name or not name then return end
  local a, b = t.name:lower(), name:lower()
  if a == b or a:gsub("^an? ", ""):gsub("^the ", "") == b:gsub("^an? ", ""):gsub("^the ", "") then return t end
end

-- char.quests: the game's own quest log; many phases name the exact room
function M.gmcpQuestRoom(qid, n)
  local q = G("char.quests")
  q = type(q) == "table" and (q["q" .. tostring(qid)] or q[tostring(qid)]) or nil
  if type(q) ~= "table" or type(q.goals) ~= "table" then return end
  for _, g in ipairs(q.goals) do
    if tonumber(g.phase_number) == tonumber(n) then
      local r = tonumber(g.room_target)
      if r and r > 0 then return r end
      return
    end
  end
end

-- room.info flags ("safe, indoors, no-npcs, reinforced, library"); nil when GMCP isn't about this room
function M.gmcpRoomFlags(id)
  local info = G("room.info")
  if type(info) ~= "table" or tonumber(info.num) ~= tonumber(id) or type(info.flags) ~= "string" then return end
  local out = {}
  for raw in info.flags:gmatch("[^,]+") do
    local f = trim(raw)
    if f ~= "" and f ~= "_empty" then out[#out + 1] = f end
  end
  return out
end

-- char.quests: the game tells you when a quest in your log changes - abandoned quests come off
-- the quest HUD, completed ones are marked, new ones are known as active
function M.onGmcpQuests()
  local all = G("char.quests")
  if type(all) ~= "table" then return end
  local changed = false
  for key, q in pairs(all) do
    local id = tostring(key):match("^q(%d+)$")
    local info = type(q) == "table" and q.quest_info
    if id and type(info) == "table" then
      local Q = M.quests[id] or {}
      M.quests[id] = Q
      if info.name and not Q.name then Q.name = info.name end
      -- quest_info.timer: when time runs out (a Unix time), -1 for no limit
      local tm = tonumber(info.timer)
      if info.completed ~= true and tm then
        local dl = tm > 0 and tm or nil
        if Q.deadline ~= dl then Q.deadline = dl; changed = true end
      end
      local pinned = M.cfg.questPins and M.cfg.questPins[id]
      if info.abandoned == true then
        if Q.active ~= false or pinned then changed = true end
        Q.active = false
        if pinned then
          M.cfg.questPins[id] = nil
          M.notifyQuest((Q.name or ("#" .. id)) .. " abandoned - unpinned")
        end
      elseif info.completed == true then
        if not Q.complete then
          changed = true
          if Q.name then M.questMarkComplete(Q.name) else Q.complete = true end
        end
      elseif Q.active ~= true then
        Q.active, changed = true, true
      end
      -- each step: done or not, and its text once it's no longer hidden
      if not info.abandoned and type(q.goals) == "table" then
        M.questGmcpAt[id] = os.time()
        if M.questGoals(id, Q, q.goals) then changed = true end
      end
    end
  end
  if changed then
    M.cfg.quests = M.quests
    M.saveSettings()
    pcall(M.drawQuestTracker)
  end
end

-- GMCP goals -> the quest's steps. Returns true if anything changed.
function M.questGoals(id, Q, goals)
  Q.phases = Q.phases or {}
  local byN, changed, newlyDone = {}, false, nil
  for _, ph in ipairs(Q.phases) do byN[ph.n] = ph end
  for _, g in ipairs(goals) do
    local n = tonumber(g.phase_number)
    if n then
      local raw = tostring(g.goal_string or ""):match("^[^\r\n]*") or ""
      raw = trim(raw:gsub("^%*", ""):gsub("^Phase %d+:%s*", ""))
      local fresh = raw ~= "" and M.phaseFromText(raw) or nil
      local ph = byN[n]
      if not ph then
        ph = fresh or { text = "(step " .. n .. ")" }
        ph.n = n
        Q.phases[#Q.phases + 1] = ph
        byN[n] = ph
        changed = true
      elseif fresh and ph.text and ph.text:match("^%(Hidden") then
        ph.text, ph.area, ph.tags, changed = fresh.text, fresh.area, fresh.tags, true
      end
      local done = g.phase_complete == true
      if (ph.done and true or false) ~= done then
        if done then newlyDone = ph end
        ph.done, changed = done, true
      end
    end
  end
  if changed then
    table.sort(Q.phases, function(a, b) return a.n < b.n end)
    Q.total, Q.done = #Q.phases, 0
    for _, ph in ipairs(Q.phases) do if ph.done then Q.done = Q.done + 1 end end
    if newlyDone and (M.cfg.questPins or {})[id] then
      M.notifyQuest((Q.name or ("#" .. id)) .. ": step " .. newlyDone.n .. " done (" .. Q.done .. "/" .. Q.total .. ")")
    end
  end
  return changed
end

-- a line about one of your quests being (partly) done: re-check that quest quietly, so the HUD
-- shows the game's own record of which steps are done, whatever the wording
-- "You have completed a part of quest #52, 'Jail Time'!" - GMCP normally brings the new state at the
-- same moment; if it hasn't within a couple of seconds, ask the game quietly (quest info 52)
M.questGmcpAt = M.questGmcpAt or {}
function M.noteQuestProgress(l)
  if M.cap or not l:lower():find("complet", 1, true) then return end
  local id = l:match("[Qq]uest #(%d+)")
  local name = l:match("[Qq]uest #%d+,? '(.-)'") or l:match("[Qq]uest '(.-)'")
  if not id and name then
    for qid, Q in pairs(M.quests or {}) do if Q.name and Q.name:lower() == name:lower() then id = qid; break end end
  end
  if not id or not (M.cfg.questPins or {})[id] then return end
  local t0 = os.time()
  if M.questProgressTimer then killTimer(M.questProgressTimer) end
  M.questProgressTimer = tempTimer(2, function()
    M.questProgressTimer = nil
    if (M.questGmcpAt[id] or 0) >= t0 - 2 then return end   -- GMCP already brought it
    M.questRefresh(id)
  end)
  return id
end

-- combat mode mxp: the game prints no combat text and sends char.combat_mxp each round instead
-- (counts of hits, misses and defences both ways, both sides' health, distance and your range).
-- Oven draws one line per round, and a summary when the fight ends.
local function pctBar(p, n)
  p = math.max(0, math.min(100, tonumber(p) or 0))
  local k = math.floor(n * p / 100 + 0.5)
  return string.rep("█", k) .. string.rep("░", n - k)
end
M.pctBar = pctBar
local function hpCol(p) p = tonumber(p) or 0; return p >= 70 and C.plus or (p >= 35 and C.title or C.minus) end

function M.onCombatRound()
  local r = G("char.combat_mxp")
  if type(r) ~= "table" or not r.opponent_name then return end
  local n = function(k) return tonumber(r[k]) or 0 end
  -- one fight per opponent: a round against someone else doesn't end this one
  M.fights = M.fights or {}
  local key = r.opponent_name:lower()
  local F = M.fights[key]
  if not F then
    M.fightOrder = (M.fightOrder or 0) + 1
    F = { key = key, name = r.opponent_name, rounds = 0, hit = 0, miss = 0, parried = 0, took = 0, missed = 0, defended = 0,
          order = M.fightOrder }
    M.fights[key] = F
  end
  M.fight = F
  F.rounds = F.rounds + 1
  F.hit, F.miss, F.parried = F.hit + n("you_hit"), F.miss + n("you_miss"), F.parried + n("opponent_defends")
  F.took, F.missed, F.defended = F.took + n("opponent_hits"), F.missed + n("opponent_misses"), F.defended + n("you_defend")
  M.roundSeq = (M.roundSeq or 0) + 1
  F.lastPct, F.at, F.seq = n("opponent_hp_percent"), os.time(), M.roundSeq
  F.room = F.room or tonumber((G("room.info") or {}).num)
  -- rounds come every few seconds; none for a while = the fight's over (combat mode changed, it ended
  -- some way Oven didn't see). The game doesn't send char.status while you fight, so don't wait on it.
  if F.timer then killTimer(F.timer) end
  F.timer = tempTimer(10, function() F.timer = nil; if M.fights[key] == F then M.fightSummary(nil, F) end end)
  pcall(M.drawCombatBar)
  if not M.cfg.combatLines then return end
  -- "⚔ a mental patient ██▌░░ 27%   you hit 1 · it missed 1   you 100%"
  local segs = { { C.dim, "⚔ " }, { C.item, r.opponent_name .. " " },
                 { hpCol(r.opponent_hp_percent), pctBar(r.opponent_hp_percent, 8) }, { hpCol(r.opponent_hp_percent), string.format(" %d%%", n("opponent_hp_percent")) } }
  local mine, theirs = {}, {}
  local function add(list, k, word, col) if n(k) > 0 then list[#list + 1] = { col, n(k) .. " " .. word } end end
  add(mine, "you_hit", "hit", C.plus); add(mine, "you_miss", "missed", C.dim); add(mine, "opponent_defends", "blocked", C.dim)
  add(theirs, "opponent_hits", "hit", C.minus); add(theirs, "opponent_misses", "missed", C.dim); add(theirs, "you_defend", "defended", C.plus)
  local function list(label, l)
    if #l == 0 then return end
    segs[#segs + 1] = { C.dim, "   " .. label .. " " }
    for i, x in ipairs(l) do
      if i > 1 then segs[#segs + 1] = { C.dim, " · " } end
      segs[#segs + 1] = x
    end
  end
  list("you", mine); list("it", theirs)
  segs[#segs + 1] = { C.dim, "   you " }
  segs[#segs + 1] = { hpCol(r.your_hp_percent), n("your_hp_percent") .. "%" }
  -- out of reach: say so
  if n("distance_to_opponent") > n("your_weapon_range") and n("your_weapon_range") > 0 then
    segs[#segs + 1] = { C.flag, string.format("   out of reach (%d, your range %d)", n("distance_to_opponent"), n("your_weapon_range")) }
  end
  M.combatEcho(segs)
end

-- a line in the game text, above the prompt
function M.combatEcho(segs)
  local t = {}
  for _, s in ipairs(segs) do
    local c = type(s[1]) == "table" and s[1] or (color_table and color_table[s[1]]) or { 192, 192, 192 }
    t[#t + 1] = string.format("<%d,%d,%d>", c[1], c[2], c[3]) .. s[2]
  end
  local cur = ""
  pcall(function() moveCursorEnd("main"); cur = getCurrentLine("main") or "" end)
  decho("main", ((cur ~= "") and "\n" or "") .. table.concat(t) .. "<r>\n")
end

-- the fight is over (it died, or you stopped fighting): one line for the whole fight
function M.fightSummary(how, F)
  F = F or M.fight
  if not F then return end
  if (M.fights or {})[F.key] == F then M.fights[F.key] = nil end
  if M.fight == F then M.fight = nil end
  if F.timer then killTimer(F.timer); F.timer = nil end
  pcall(M.drawCombatBar)
  if not F or F.rounds == 0 or not M.cfg.combatLines then return end
  local function rate(a, b) return (a + b) > 0 and string.format(" (%d%%)", math.floor(a * 100 / (a + b) + 0.5)) or "" end
  M.combatEcho({ { C.dim, "⚔ " }, { C.item, F.name }, { C.dim, how and ("  " .. how) or "" },
    { C.dim, string.format("  ·  %d round%s  ·  you hit ", F.rounds, F.rounds == 1 and "" or "s") },
    { C.plus, F.hit .. "/" .. (F.hit + F.miss + F.parried) }, { C.dim, rate(F.hit, F.miss + F.parried) },
    { C.dim, "  ·  it hit " }, { C.minus, F.took .. "/" .. (F.took + F.missed + F.defended) }, { C.dim, rate(F.took, F.missed + F.defended) },
    { C.dim, F.defended > 0 and ("  ·  you defended " .. F.defended) or "" } })
end

-- "X has been slain!" for the one you're fighting, or no longer fighting: the fight's over
function M.noteFightEnd(l)
  local who = l:match("^%s*(.-) has been slain!")
  if not who then return end
  local function bare(x) return (x:lower():gsub("^the ", ""):gsub("^an? ", "")) end
  for _, F in pairs(M.fights or {}) do
    if bare(who) == bare(F.name) then
      -- after the line has been drawn (echoing while a line is being read would join the two)
      if F.timer then killTimer(F.timer); F.timer = nil end
      tempTimer(0, function() M.fightSummary("slain", F) end)
      return
    end
  end
end
-- you left the room (fled, walked out): the fight's over
function M.onFightRoom()
  local id = tonumber((G("room.info") or {}).num)
  if not id then return end
  local done = {}
  for _, F in pairs(M.fights or {}) do if F.room and id ~= F.room then done[#done + 1] = F end end
  for _, F in ipairs(done) do M.fightSummary("you left", F) end
end
function M.onFightStatus()
  local s = G("char.status")
  if M.fights and next(M.fights) and type(s) == "table" and s.position and s.position ~= "fighting" then
    -- a moment later, so "has been slain" (text) gets to say how it ended first
    tempTimer(1, function()
      local done = {}
      for _, F in pairs(M.fights or {}) do if os.time() - (F.at or 0) >= 1 then done[#done + 1] = F end end
      for _, F in ipairs(done) do M.fightSummary(nil, F) end
    end)
  end
end

function M.gmcpHandlersList()
  return {
    registerAnonymousEventHandler("gmcp.char.quests", function() pcall(M.onGmcpQuests) end),
    registerAnonymousEventHandler("gmcp.char.combat_mxp", function() pcall(M.onCombatRound) end),
    registerAnonymousEventHandler("gmcp.char.status", function() pcall(M.onFightStatus) end),
    registerAnonymousEventHandler("gmcp.room.info", function() pcall(M.onFightRoom) end),
    -- a new connection: read your aliases again at its first prompt
    registerAnonymousEventHandler("sysConnectionEvent", function() M.aliasesRead, M.aliasesAsked = nil, nil end),
    registerAnonymousEventHandler("gmcp.char.status", function() pcall(M.onGmcpStatus) end),
    -- HP / SP / ST as they change (mid-fight too): redraw the bar
    registerAnonymousEventHandler("gmcp.char.vitals", function() if M.cfg.bar then pcall(M.drawBar) end end),
    registerAnonymousEventHandler("gmcp.char.maxstats", function() pcall(M.onGmcpMaxStats) end),
    registerAnonymousEventHandler("gmcp.char.worth", function() pcall(M.onGmcpWorth) end),
    registerAnonymousEventHandler("gmcp.char.affect_application_msg", function() pcall(M.onGmcpAffect) end),
    registerAnonymousEventHandler("gmcp.char.lasttargeted", function() pcall(M.onGmcpTarget) end),
  }
end

-- whatever GMCP already holds when Oven starts (an update mid-session)
function M.gmcpCatchUp()
  pcall(M.onGmcpStatus); pcall(M.onGmcpMaxStats); pcall(M.onGmcpWorth); pcall(M.onGmcpTarget)
end

function M.barUpdate(d)
  M.raiseQuestHud()
  -- the mount line comes right before the prompt; none this time = not riding
  M.mount, M.mountPending = M.mountPending, nil
  if not M.bar or not M.bar.rawEcho then M.showBar(true) end
  -- re-layout if something else (e.g. the base UI dock) changed the side borders
  local ok, r = pcall(getBorderRight)
  if ok and r and r ~= M.barRight then M.layoutBar() end
  M.lastPromptDecho, M.lastPromptText = d, line
  M.drawBar()
end

---------------------------------------------------------------------------
-- Capture engine
---------------------------------------------------------------------------
M.queue = {}
M.cap = nil          -- active capture
M.history = M.history or {}

local function selectionDecho()
  selectCurrentLine()
  local ok, d = pcall(copy2decho)
  deselect()
  return ok and d or nil
end

function M.start(kind, target, cmd)
  M.cap = { kind = kind, target = target, cmd = cmd, plain = {}, decho = {}, lastAt = now(),
            hasLayout = M.formatters[kind] ~= nil }
  if kind == "help" then M.cap.gag = M.cfg.helpWindow
  else M.cap.gag = M.cfg.main == "replace" and M.cap.hasLayout end
  if M.quietQuest and kind == "quest" then
    M.cap.quiet, M.cap.gag, M.cap.quietKind = true, true, "quest"
    M.quietQuest = nil
  end
  if M.quietNext and kind == M.quietNext.kind then
    M.cap.quiet, M.cap.gag, M.cap.quietKind, M.cap.quietFn = true, true, "fn", M.quietNext.fn
    M.quietNext = nil
  elseif M.learning and kind == "item" then
    -- sbo eq learn: record the item, show nothing
    M.cap.quiet, M.cap.gag = true, true
    M.learning.started = true
  end
  M.cap.maxTimer = tempTimer(M.cfg.maxTime, function() M.finish("maxtime") end)
end

-- Your aliases in the game ("alias qr quest request"): a command is read as what it stands for, so
-- qr is a quest request to Oven too. The list is read quietly at the start of each session, and kept
-- up to date from the game's own messages as you add, change and remove them.
function M.expandAlias(cmd)
  local first, rest = tostring(cmd or ""):match("^%s*(%S+)(.*)$")
  local full = first and (M.cfg.gameAliases or {})[first:lower()]
  return full and (full .. rest) or cmd
end

-- a command Oven sends by itself, noted so onSend can tell it from one you typed (M.lastUserCmdAt)
function M.sendOwn(cmd, echo)
  M.ownCmds = M.ownCmds or {}
  M.ownCmds[cmd] = (M.ownCmds[cmd] or 0) + 1
  send(cmd, echo)
end

-- you haven't typed anything for a while: time for Oven's own errands that can wait
function M.userIdle(secs)
  return now() - (M.lastUserCmdAt or 0) >= (secs or 2)
end

function M.onSend(_, cmd)
  local own = M.ownCmds and M.ownCmds[cmd]
  if own and own > 0 then M.ownCmds[cmd] = (own > 1) and (own - 1) or nil
  else M.lastUserCmdAt = now() end
  -- everything below sees what an alias stands for ("qr" -> "quest request"), recordings too
  cmd = M.expandAlias(cmd)
  pcall(M.recordCommand, cmd)
  pcall(M.noteLootCommand, cmd)
  pcall(M.noteEnterCommand, cmd)
  pcall(M.noteRunCommand, cmd)
  if not M.cfg.enabled then return end
  local kind, target = M.classify(cmd)
  if not kind then return end
  if M.cap then
    M.queue[#M.queue + 1] = { kind, target, cmd }
  else
    M.start(kind, target, cmd)
  end
end

-- Remove empty lines directly above the current (prompt) line, leaving the cursor on it.
function M.dropBlankAbove()
  if not M.cfg.barBlank then return end
  for _ = 1, 2 do
    local ok, ln = pcall(getLineNumber)
    if not ok or not ln or ln < 1 then return end
    local okL, prev = pcall(getLines, ln - 1, ln)
    local text = okL and type(prev) == "table" and prev[1]
    if type(text) ~= "string" or text:match("%S") then return end
    moveCursor(0, ln - 1)
    deleteLine()
    moveCursor(0, ln - 1)   -- the prompt has moved up one line
  end
end

-- Does a line belong to the command's output, or is it someone else's activity that
-- happened to arrive meanwhile ("Ferdinand drops a ripe pumpkin.")? Lines that don't
-- belong are left alone in the main window, in the order they arrived.
M.shapes = {
  eq = function(t)
    return t:match("^You are using") or t:match("^<[%a][%a ']*>") or t:match("^%(%a[%a ]-%s*%)%s+%-?%d")
      or t:match("^Current Armor Resistance") or t:match("^Your value if CPKed") or t:match("^You have a %d+%% chance")
      or t:match("^Equipped weapon damage") or t:match("^With .-, you will deal") or t:match("^%-?%d+%%? [%a ]-:")
      or t:match("^You are not using") or t:match("^Nothing")
  end,
  contents = function(t, l)
    return l:match("^%s%s+%S") or t:match("^%(%s*%d+%)") or t == "Search inventory" or t:match(":$")
      or t:match("^A total of") or t:match("^You may carry") or t:match("^Nothing")
  end,
  score = function(t, l)
    return t:match("^Player Information") or l:match("^%s%s%S") or t:match("^%*")
  end,
  levels = function(t) return t:match("^%[Level:") end,
  where = function(t, l)
    return t:match("^Where is what%?") or t:match("^You sense that ") or t:match("^When you do find")
      or (l:match("^[%w%-]+%s%s") and not t:match("[%.!?']$")) or t:match("^[%w%-]+$") ~= nil
  end,
  shop = function(t)
    return t:match("^Welcome to ") or t:match("^You have [%d,]+ gp on hand") or t:match("^No%.%s+Item Name")
      or t:match("^%d+%)%s") or t:match("^There isn't a shopkeeper") or t:match("^You can't do that")
      or t:match("^You have [%d,]+ [%a ]+ available") or t:match("^%* Type %u")
      or (M.shopRefusal(t) ~= nil)
  end,
  quest = function(t, l, cap)
    if not cap.questStarted then
      if t:match("^%a* ?Quest #%d+") or t:match("^This quest %[%d+%]") or t:match("^Usage: quest")
         or t:match("^You must seek out a quest master") or t:match("^You are not on")
         or t:match("^You have no") or t:match("^A total of %[") then
        cap.questStarted = true
        return true
      end
      return false
    end
    return not M.looksLikeActivity(t)
  end,
  affects = function(t)
    return t:match("^You are affected") or t:match("^You are not affected") or t:match("^%*")
      or t:match("^%a[%a ]-:%s") or t:match("^Total of") or t:match("^%[AFFECTS")
  end,
}

-- free-text output (item / creature looks, help): only lines that look like other
-- people's activity AND arrive after a pause are treated as not belonging, so a
-- description that itself contains "X tells you '...'" stays intact
M.activity = {
  " says '", " says, '", " asks '", " exclaims '", " tells you '", " tells the group '", " yells '",
  " shouts '", " whispers ", " gossips", " chats '", " arrives", " has arrived", " leaves ", " left ",
  " drops ", " puts ", " gets ", " picks up ", " wears ", " wields ", " removes ", " gives ",
  " eats ", " drinks ", " is DEAD", " dies", "^You hear ", "^%[%a[%w%s]*%] ",
}
function M.looksLikeActivity(t)
  for _, p in ipairs(M.activity) do
    if t:find(p, 1, p:sub(1, 1) ~= "^") then return true end
  end
  return false
end

function M.belongs(cap, l)
  local t = trim(l)
  if t == "" then return true end
  local shape = M.shapes[cap.kind]
  local ok
  if shape then
    ok = shape(t, l, cap) and true or false
  else
    local gap = now() - (cap.lastAt or 0)
    ok = not (M.looksLikeActivity(t) and (#cap.plain == 0 or gap > 0.15))
  end
  if ok then cap.lastAt = now() end
  return ok
end

local function isPromptLine()
  local ok, p = pcall(isPrompt)
  if ok and p then return true end
  return M.cfg.promptPattern ~= "" and line:match(M.cfg.promptPattern) ~= nil
end

M.recentLines = M.recentLines or {}
M.killCtxLogged = M.killCtxLogged or 0
function M.noteKillContext(l)
  -- remember the last 8 lines; when exp is gained (not from a quest reward), log them once
  -- so the game's wording for a kill can be learned
  local R = M.recentLines
  if (l:match("^%s*You gain [%d,]+ experience") or l:match("^%s*You receive [%d,]+ experience"))
     and M.cfg.samples and M.killCtxLogged < 30 then
    M.killCtxLogged = M.killCtxLogged + 1
    local f = io.open(M.samplesFile, "a")
    if f then
      f:write("===== " .. os.date("%Y-%m-%d %H:%M:%S") .. " | kind=killctx | cmd=\n")
      for i = math.max(1, #R - 7), #R do f:write(R[i], "\n") end
      f:write(l, "\n===== end\n\n")
      f:close()
    end
  end
  R[#R + 1] = l
  if #R > 30 then table.remove(R, 1) end
end

-- Recorder. Game output is cut into blocks - everything up to each prompt - and each block keeps
-- the commands that caused it and the GMCP that changed with it. The last cfg.recWindow blocks stay
-- in memory (a sliding window); they're written to oven_record.txt only when there's a reason:
-- `sbo debug record save`, a death, or (later) a block Oven can't make sense of. `sbo debug record start [minutes]`
-- writes every block as it happens instead. The file is rotated to oven_record.old.txt at 4 MB.
M.recordFile = getMudletHomeDir() .. "/oven_record.txt"
local REC_ROTATE = 4 * 1024 * 1024
local REC_BLOCK_LINES = 400
local SECRET_CMD = { "^%s*passw", "^%s*pass%s" }
M.win = M.win or { seq = 0, savedSeq = 0, blocks = {} }
M.recCur = M.recCur or { lines = {}, cmds = {} }
M.gmcpSeen = M.gmcpSeen or {}      -- package -> its last Lua source, to spot what changed
M.gmcpDirty = M.gmcpDirty or {}    -- top-level GMCP names updated since the last block

-- every GMCP package two levels down (gmcp.room.info, gmcp.char.vitals...) as Lua source;
-- `tops` limits it to some top-level names
function M.gmcpPackages(tops)
  local out = {}
  if type(gmcp) ~= "table" then return out end
  for top, v in pairs(gmcp) do
    if type(v) == "table" and (not tops or tops[top]) then
      local leaf = true
      for k, x in pairs(v) do
        if type(x) == "table" then leaf = false; out[top .. "." .. tostring(k)] = (ser(x):gsub("\\\n", "\\n")) end
      end
      if leaf then out[top] = (ser(v):gsub("\\\n", "\\n")) end
    end
  end
  return out
end

-- Mudlet raises "gmcp.<package>" events as messages arrive; listen on each top-level name we've
-- seen so a prompt only has to look at what actually changed
M.gmcpHandlers = M.gmcpHandlers or {}
function M.gmcpWatch()
  if type(gmcp) ~= "table" then return end
  local H = M.gmcpHandlers
  local function watch(ev, top)
    if H[ev] then return end
    H[ev] = registerAnonymousEventHandler(ev, function() M.gmcpDirty[top] = true end)
    M.gmcpDirty[top] = true
  end
  for top, v in pairs(gmcp) do
    if type(v) == "table" then
      watch("gmcp." .. top, top)
      for k, x in pairs(v) do if type(x) == "table" then watch("gmcp." .. top .. "." .. tostring(k), top) end end
    end
  end
end
function M.gmcpUnwatch()
  for _, h in pairs(M.gmcpHandlers or {}) do pcall(killAnonymousEventHandler, h) end
  M.gmcpHandlers = {}
end

local function gmcpChanges()
  local tops = M.gmcpDirty
  M.gmcpDirty = {}
  if not next(tops) then return {} end
  local now_, changed = M.gmcpPackages(tops), {}
  for name, v in pairs(now_) do
    if M.gmcpSeen[name] ~= v then changed[#changed + 1] = { name, v }; M.gmcpSeen[name] = v end
  end
  table.sort(changed, function(a, b) return a[1] < b[1] end)
  return changed
end

local function blockText(b)
  local out = { "===== " .. os.date("%Y-%m-%d %H:%M:%S", b.t) .. " | cmd=" .. table.concat(b.cmds, " ; ")
    .. " | room=" .. tostring(b.room or "") .. "\n" }
  for _, g in ipairs(b.gmcp) do out[#out + 1] = "@gmcp " .. g[1] .. " = " .. g[2] .. "\n" end
  -- line colours as runs: "@fg 1-3=192,192,192 5=0,255,255"
  if b.fg then
    local runs, i, n = {}, 1, #b.lines
    while i <= n do
      local c = b.fg[i]
      local j = i
      while j < n and b.fg[j + 1] == c do j = j + 1 end
      if c then runs[#runs + 1] = (i == j and tostring(i) or (i .. "-" .. j)) .. "=" .. c end
      i = j + 1
    end
    if #runs > 0 then out[#out + 1] = "@fg " .. table.concat(runs, " ") .. "\n" end
  end
  for _, x in ipairs(b.lines) do out[#out + 1] = x .. "\n" end
  out[#out + 1] = "\n"
  return table.concat(out)
end

local function recOpen()
  local f = io.open(M.recordFile, "r")
  if f then
    local size = f:seek("end"); f:close()
    if size and size > REC_ROTATE then
      local old = M.recordFile:gsub("%.txt$", ".old.txt")
      os.remove(old); os.rename(M.recordFile, old)
    end
  end
  return io.open(M.recordFile, "a")
end

-- write the window's blocks not saved yet; returns how many
function M.windowSave(reason)
  local W, cur, out = M.win, M.recCur, {}
  for _, b in ipairs(W.blocks) do
    if b.seq > W.savedSeq then out[#out + 1] = blockText(b) end
  end
  -- and what's arrived since the last prompt
  local from = (cur.savedLines or 0) + 1
  if #cur.lines >= from then
    local part = {}
    local partFg = {}
    for i = from, #cur.lines do part[#part + 1] = cur.lines[i]; partFg[#part] = (cur.fg or {})[i] end
    out[#out + 1] = blockText({ t = os.time(), cmds = from == 1 and cur.cmds or {}, room = M.currentRoom and M.currentRoom(), gmcp = {}, lines = part, fg = partFg })
  end
  if #out == 0 then return 0 end
  local f = recOpen()
  if not f then return 0 end
  f:write("##### saved " .. os.date("%Y-%m-%d %H:%M:%S") .. " (" .. (reason or "sbo debug record save") .. ") | Oven " .. M.version .. "\n")
  f:write(table.concat(out))
  f:write("##### end\n\n")
  f:close()
  W.savedSeq = W.seq
  cur.savedLines = #cur.lines
  return #out
end

function M.recordStart(minutes)
  minutes = tonumber(minutes) or 30
  -- what's in memory and not yet written goes first, so nothing before the recording is lost
  pcall(M.windowSave, "before sbo debug record")
  M.rec = { untilT = os.time() + minutes * 60, n = 0 }
  local f = recOpen()
  if f then
    f:write("##### recording started " .. os.date("%Y-%m-%d %H:%M:%S") .. " | Oven " .. M.version .. "\n")
    for name, v in pairs(M.gmcpPackages()) do f:write("@gmcp " .. name .. " = " .. v .. "\n") end
    f:write("\n"); f:close()
  end
  M.win.savedSeq = M.win.seq
end

function M.recordStop(why)
  if not M.rec then return end
  local n = M.rec.n
  M.rec = nil
  local f = io.open(M.recordFile, "a")
  if f then f:write("##### recording stopped (" .. (why or "off") .. ")\n\n"); f:close() end
  return n
end

function M.recordCommand(cmd)
  for _, p in ipairs(SECRET_CMD) do if cmd:lower():match(p) then cmd = "(hidden)" end end
  local c = M.recCur.cmds
  if #c < 50 then c[#c + 1] = cmd end
end

-- the colour of a line's first visible character ("r,g,b"), so blocks can tell a room's
-- description from the creatures in it; two calls per line, nothing per character
function M.lineFg(l)
  local i = l:find("%S")
  if not i or not selectSection or not getFgColor then return end
  selectSection(i - 1, 1)
  local r, g, bl = getFgColor()
  deselect()
  if r then return r .. "," .. g .. "," .. bl end
end

function M.recordLine(l, prompt)
  local cur = M.recCur
  cur.lines[#cur.lines + 1] = l
  cur.fg = cur.fg or {}
  local okF, fg = pcall(M.lineFg, l)
  cur.fg[#cur.lines] = okF and fg or false
  -- the full colours of anything that may be chat, so the Chat tab shows it as the game did
  if M.chatFind(l) then
    cur.decho = cur.decho or {}
    local okD, d = pcall(selectionDecho)
    cur.decho[#cur.lines] = okD and d or nil
  end
  -- a block ends at the prompt; if no prompt has come for a long while (it isn't recognised yet),
  -- a blank line ends it, so kills and loot are still read promptly
  if not prompt and #cur.lines < REC_BLOCK_LINES and not (#cur.lines >= 60 and not l:match("%S")) then return end
  pcall(M.gmcpWatch)
  local W = M.win
  W.seq = W.seq + 1
  if cur.savedLines then
    local rest = {}
    local restFg = {}
    local restD = {}
    for i = cur.savedLines + 1, #cur.lines do rest[#rest + 1] = cur.lines[i]; restFg[#rest] = (cur.fg or {})[i]; restD[#rest] = (cur.decho or {})[i] end
    cur.lines, cur.cmds, cur.fg, cur.decho = rest, {}, restFg, restD
  end
  local b = { seq = W.seq, t = os.time(), cmds = cur.cmds, lines = cur.lines, fg = cur.fg or {}, decho = cur.decho,
              room = M.currentRoom and M.currentRoom(), gmcp = gmcpChanges() }
  M.recCur = { lines = {}, cmds = {} }
  b.prompt = prompt
  pcall(M.onBlock, b)
  local max = tonumber(M.cfg.recWindow) or 300
  if max > 0 then
    W.blocks[#W.blocks + 1] = b
    while #W.blocks > max do table.remove(W.blocks, 1) end
  end
  local R = M.rec
  if R then
    local f = recOpen()
    if f then f:write(blockText(b)); f:close() end
    W.savedSeq = W.seq
    R.n = R.n + 1
    if os.time() > R.untilT then
      local n = M.recordStop("time's up")
      M.say("recording finished: " .. n .. " blocks saved to oven_record.txt")
    end
  end
end

-- Blocks. Each finished block is recognised once - "room", "help"... - by the recognisers in
-- M.blockKinds, then handed to the readers that asked for that kind. A reader only ever sees the
-- part of the output it understands; adding one is one M.addBlockReader call.
M.blockKinds, M.blockReaders = {}, {}
function M.addBlockKind(name, find) M.blockKinds[#M.blockKinds + 1] = { name = name, find = find } end
function M.addBlockReader(name, kind, read) M.blockReaders[#M.blockReaders + 1] = { name = name, kind = kind, read = read } end

function M.onBlock(b)
  b.kinds = {}
  for _, k in ipairs(M.blockKinds) do
    local ok, seg = pcall(k.find, b)
    if ok and seg then b.kinds[k.name] = seg end
  end
  for _, r in ipairs(M.blockReaders) do
    local seg = r.kind == "*" and b.kinds or b.kinds[r.kind]
    if seg then
      local ok, err = pcall(r.read, b, seg)
      if not ok and M.cfg.samples then M.log("<dim_grey>[sbo] " .. r.name .. ": " .. tostring(err) .. "<reset>") end
    end
  end
  return b.kinds
end

-- Materia Magica's room view:
--    Magical Training                                       -      -      -      <- name, then a minimap
--   (-------------------------------------------------)     # <---(M)---> -      <- the ruler
--                                                           -      -      -
--     A spacious area below the Guildhall...                                     <- description
--        A bright orange piece of bubble gum has been abandoned on the ground.   <- items: indented
--   [Trainer] A well-muscled woman dressed in a sleeveless tunic stands here.    <- who's here
-- It counts only when the name matches GMCP's room.info, so the room number is certain.
local ROOM_RULER = "^%(%-%-%-%-+%)"
function M.findRoomView(b)
  local L = b.lines
  local at
  for i = #L, 2, -1 do if L[i]:match(ROOM_RULER) then at = i; break end end
  if not at then return end
  local title = trim((L[at - 1]:gsub("%s%s%s+.*$", "")))
  local info = type(gmcp) == "table" and gmcp.room and gmcp.room.info or {}
  local id = tonumber(info.num)
  if not id or title == "" or title:lower() ~= trim(tostring(info.name or "")):lower() then return end
  local seg = { room = id, title = title, items = {}, here = {} }
  local last = #L
  if b.prompt then last = last - 1 end
  -- description: from the first line indented two spaces to the line ending in two spaces
  -- (or filling the width); then items (indented) and who's here, up to the prompt
  local i = at + 2
  while i <= last and not L[i]:match("^  %S") do i = i + 1 end
  local desc = {}
  local fg = b.fg or {}
  local descFg = fg[i]
  while i <= last do
    local x = L[i]
    if #desc > 0 then
      if x:match("^     %S") or x:match("^%*") or x:match("^%[") or not x:match("%S") then break end
      -- with colours: the description is one colour, and whatever follows isn't
      if descFg and fg[i] and fg[i] ~= descFg then break end
    end
    desc[#desc + 1] = x
    i = i + 1
    -- without colours: its last line ends in two spaces (unless it filled the width)
    if not descFg and x:match("%S  $") then break end
  end
  seg.desc = desc
  for k = i, last do
    local x = L[k]
    if x:match("^     %S") then seg.items[#seg.items + 1] = trim(x)
    elseif x:match("%S") then seg.here[#seg.here + 1] = x end
  end
  return seg
end
M.addBlockKind("room", M.findRoomView)

-- a help page: "[1090 ] FEEDING", or the reply to a help command
M.addBlockKind("help", function(b)
  for _, x in ipairs(b.lines) do
    if x:match("%S") then
      if x:match("^%[%s*%d+%s*%] %u") then return { topic = trim(x:gsub("^%[%s*%d+%s*%]", "")) } end
      break
    end
  end
  for _, c in ipairs(b.cmds) do if c:lower():match("^%s*help%s") then return { topic = c } end end
  if M.cap and M.cap.kind == "help" then return { topic = M.cap.target or "" } end
end)

-- help pages teach Oven about classes and races: `help classes` (which group each class is in),
-- a class's page (its primary attribute), a race's page (weapon bonuses, maximum stats).
-- Only help pages are read, so the same words elsewhere (chat, a quest text) aren't taken for them.
M.addBlockReader("help_learn", "help", function(b)
  local last = #b.lines - (b.prompt and 1 or 0)
  for i = 1, last do
    local l = b.lines[i]
    pcall(M.noteClassHelp, l); pcall(M.noteRaceHelp, l); pcall(M.noteClassPrimary, l)
  end
end)
-- a page can run over several blocks (the game's pager); the first block that isn't help ends it,
-- closing any table that ran to the end of the page
M.addBlockReader("help_end", "*", function(b, kinds)
  if kinds.help then return end
  if M.raceHelp then pcall(M.noteRaceHelp, "") end
  if M.classHelp then pcall(M.noteClassHelp, "") end
  M.classHelp, M.raceHelp = nil, nil
end)

-- kills, the exp they give, and pickups - in the order they happened; never from a help page
local function expGain(l)
  if l:find("need", 1, true) then return end
  local n = l:match("^%s*You receive ([%d,]+) experience") or l:match("^%s*You gain ([%d,]+) experience")
  return n and tonumber((n:gsub(",", "")))
end
M.addBlockReader("kills_loot", "*", function(b, kinds)
  if kinds.help then return end
  local last = #b.lines - (b.prompt and 1 or 0)
  for i = 1, last do
    local l = b.lines[i]
    local slain = l:match("^%s*(.-) has been slain!%s*$")
    if slain and slain ~= "" then pcall(M.recordKill, slain) end
    local n = expGain(l)
    if n and n > 0 then pcall(M.creditKillExp, n) end
    local okL, loot = pcall(M.parseLoot, l)
    if okL and loot then pcall(M.recordLoot, loot); pcall(M.notePickup, loot) end
  end
  if M.pickupPending and b.prompt then
    local p = b.lines[#b.lines]   -- the prompt line itself
    tempTimer(0.5, function() pcall(M.pickupFlush, p) end)
  end
end)

-- A shop's list ("shop list", "shop i"): kept by room, so you can look up where to buy something.
-- "Welcome to the Sushi Bar!" / "No.  Item Name   Level Amount   Cost" /
-- "     1) A bottle of soy sauce                        10    999          [        250 gold]"
function M.parseShop(lines)
  local shop, items, header = nil, {}, false
  for _, l in ipairs(lines) do
    local t = trim(l)
    local w = t:match("^Welcome to (.-)!") 
    if w then shop = w end
    if t:match("^No%.%s+Item Name%s+Level%s+Amount%s+Cost") then header = true
    elseif header then
      -- the price in gold, or another currency: "[   25 rewardunits]"
      local no, name, level, amount, cost, cur = t:match("^(%d+)%)%s+(.-)%s%s+(%d+)%s+(.-)%s+%[%s*([%d,]+)%s+([%a][%a ]-)%s*%]$")
      if no then
        items[#items + 1] = { no = tonumber(no), item = trim(name), level = tonumber(level), amount = trim(amount),
                              cost = tonumber((cost:gsub(",", ""))), currency = trim(cur):lower() }
      end
    end
  end
  if header and #items > 0 then
    -- "the Sushi Bar", "your local area potion shop", "Ganuk's Express Travels! (Member of …)"
    return { name = shop and shop:gsub("^your local area ", "local ") or nil, items = items }
  end
end

function M.recordShop(room, shop)
  if not room or not shop then return end
  local t = os.time()
  local known = M.dbRow("SELECT room FROM shops WHERE room = %s", room) ~= nil
  -- a line when it's in: a shop seen for the first time, or one Oven just listed by itself (so you
  -- know you can move on); a list you typed yourself is already on the screen
  local auto = M.shopAsked and M.shopAsked.room == room and t - M.shopAsked.at <= 10
  if auto then M.shopAsked = nil end
  local label = (shop.name or "a shop") .. " · " .. #shop.items .. " item" .. (#shop.items == 1 and "" or "s")
  if not known then M.say("new shop: " .. label)
  elseif auto then M.say("shop updated: " .. label) end
  M.dbx("INSERT OR REPLACE INTO shops (room, name, last) VALUES (%s, %s, %s)", room, shop.name, t)
  if not known then pcall(M.mapLearned) end
  M.dbx("DELETE FROM shop_refusals WHERE room = %s", room)
  -- the stock as it is now (what's sold out or gone is dropped from this shop's list)
  M.dbx("DELETE FROM shop_items WHERE room = %s", room)
  for _, it in ipairs(shop.items) do
    M.dbx("INSERT OR REPLACE INTO shop_items (room, no, item, level, amount, cost, last, currency) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
      room, it.no, it.item, it.level, it.amount, it.cost, t, it.currency or "gold")
  end
end

M.addBlockReader("shop_list", "*", function(b)
  local shop = M.parseShop(b.lines)
  if shop then pcall(M.recordShop, M.mapRoom or b.room, shop) end
end)

-- "A Gnomish Travel attendant tells you 'Sorry, but I cannot sell my wares to someone of your level of
-- experience.'" -> what was said (an NPC: more than one word before "tells you"; players are one word)
local REFUSE = { "cannot sell", "can't sell", "won't sell", "will not sell", "refuse to sell", "don't trade",
                 "do not trade", "not sell", "won't trade", "will not trade" }
function M.shopRefusal(t)
  local who, said = t:match("^(.-) tells you '(.*)'%s*$")
  if not who or not who:find(" ") then return nil end
  local low = said:lower()
  for _, w in ipairs(REFUSE) do if low:find(w, 1, true) then return said end end
end

function M.myLevel()
  return tonumber((M.live or {}).level) or tonumber(((M.cfg.char or {}).level))
end

-- a refusal after a shop list (yours or Oven's): remembered with your level, so Oven doesn't ask again
-- until that changes
M.addBlockReader("shop_refusal", "*", function(b)
  local asked = false
  for _, c in ipairs(b.cmds or {}) do if M.classify(c) == "shop" then asked = true end end
  if not asked then return end
  for _, l in ipairs(b.lines) do
    local said = M.shopRefusal(trim(l))
    if said and M.mapRoom then
      M.dbx("INSERT OR REPLACE INTO shop_refusals (room, said, level, t) VALUES (%s, %s, %s, %s)",
        M.mapRoom, said, M.myLevel(), os.time())
      M.noteAuto("shop", M.mapRoom, "refused: " .. said)
      M.say("won't sell to you: " .. said .. "  (Oven asks again when your level changes)")
      return
    end
  end
end)

-- Going into a shop Oven hasn't listed: it lists it quietly, once (your own lists keep it up to date). Straight
-- away, so popping in and out works (the game answers in order, from the shop); not in shops an Oven
-- walk or a signpost run only passes through (the walk's last room counts: it's over by then).
-- A shop is a room whose NPC the game tags [Shop], or one you've listed before.
M.shopTried = M.shopTried or {}
-- a traveling seller: a [Shop] NPC seen in more than one room (it walks a path; every room it's been
-- seen in stays marked). key = its line, lower-cased, as room_npcs keeps it.
function M.travelerRooms(key)
  local r = M.dbRow("SELECT COUNT(DISTINCT room) AS n FROM room_npcs WHERE key = %s", key)
  return tonumber(r and r.n) or 0
end
function M.isTraveler(key) return M.travelerRooms(key) >= 2 end

-- a shop: one Oven has listed, or a room with a shopkeeper who stays there (not a traveling seller)
function M.isShopRoom(room)
  if not room then return false end
  if M.dbRow("SELECT room FROM shops WHERE room = %s", room) then return true end
  for _, r in ipairs(M.dbRows("SELECT key FROM room_npcs WHERE room = %s AND instr(lower(ifnull(tags, '')), 'shop') > 0", room)) do
    if not M.isTraveler(r.key) then return true end
  end
  return false
end

-- what's keeping Oven from doing something by itself right now (nil: nothing)
function M.busyWhy(promptLine)
  if M.walk then return "walking" end
  if M.running then return "running (" .. tostring(M.running.name) .. ")" end
  if M.cap then return "reading a reply (" .. tostring(M.cap.kind) .. ")" end
  if M.learning or M.learnQueue then return "looking at items" end
  if M.quietNext then return "waiting for a quiet reply" end
  if M.fighting() then return "fighting" end
  if not M.inGame(promptLine) then return "not in the game (status or prompt)" end
end

-- the last few things Oven decided to do (or not) by itself: sbo debug state
M.autoNotes = M.autoNotes or {}
function M.noteAuto(what, room, result)
  table.insert(M.autoNotes, string.format("%s  %s  #%s  %s", os.date("%H:%M:%S"), what, tostring(room), result))
  while #M.autoNotes > 40 do table.remove(M.autoNotes, 1) end
end

function M.shopAutoList(room, promptLine)
  if M.cfg.shopList == false or not room then return end
  if not M.isShopRoom(room) then return end
  if room ~= M.mapRoom then return M.noteAuto("shop", room, "skipped: already left") end
  -- not while walking through, fighting, or busy; only once you're playing
  local why = M.busyWhy(promptLine)
  if why then return M.noteAuto("shop", room, "skipped: " .. why) end
  local t = os.time()
  if M.shopTried[room] and t - M.shopTried[room] < 3600 then return M.noteAuto("shop", room, "skipped: tried in the last hour") end
  -- once per shop: after the first list, the lists you type keep it up to date
  if M.dbRow("SELECT room FROM shops WHERE room = %s", room) then return M.noteAuto("shop", room, "skipped: already listed") end
  local no = M.dbRow("SELECT level FROM shop_refusals WHERE room = %s", room)
  if no and tonumber(no.level) == M.myLevel() then return M.noteAuto("shop", room, "skipped: won't sell to you at this level") end
  M.shopTried[room] = t          -- not listed yet and no answer (no shopkeeper there just now): try again in an hour
  M.noteAuto("shop", room, "shop list sent")
  M.shopAsked = { room = room, at = t }
  M.quietly("shop list", "shop", function(lines)
    M.noteAuto("shop", room, lines and ("reply: " .. #lines .. " lines") or "no reply")
  end)   -- the shop_list reader saves it
end

-- the moment GMCP says you're in a new room (before its text is read): popping in and out of shops
-- quickly leaves very little time for the game to answer from inside the shop
function M.shopOnArrive(id)
  if not id or id == M.shopCheckedRoom then return end
  M.shopCheckedRoom = id
  local ok, err = pcall(M.shopAutoList, id, M.lastStatusPrompt or M.lastPromptText)
  if not ok then M.noteAuto("shop", id, "error: " .. tostring(err)) end
end

---------------------------------------------------------------------------
-- "where is": the game points you at things in the area you're in. Oven remembers where each one is
-- (following the directions on the map), so sbo go finds them from anywhere; and it learns each area's
-- features by itself while you're idle (sbo config map.wherelearn).
---------------------------------------------------------------------------
local DIR_FULL = { n = "north", s = "south", e = "east", w = "west", ne = "northeast", nw = "northwest",
                   se = "southeast", sw = "southwest", u = "up", d = "down" }

function M.areaNow()
  local info = M.gmcpGet("room.info")
  return type(info) == "table" and info.zone and tostring(info.zone) or nil
end

-- follow "s, s, w" on the map from a room; nil if a step isn't mapped
function M.followDirs(from, dirs)
  local id = from
  for d in tostring(dirs):gmatch("[^,%s]+") do
    if not id or not roomExists(id) then return nil end
    local ok, ex = pcall(getRoomExits, id)
    if not ok or type(ex) ~= "table" then return nil end
    local full = DIR_FULL[d:lower()] or d:lower()
    id = tonumber(ex[full] or ex[d:lower()])
    if not id then return nil end
  end
  return id
end

-- "Where is what? Features that Towne of Rune might contain …:" then the names in columns
-- "You sense that food may be located s, s, w, w, w, w, w, w, w, w, w, s."
function M.readWhere(lines, area)
  local inList, listArea, features = false, nil, {}
  local answers = {}
  for _, l in ipairs(lines) do
    local t = trim(l)
    local a = t:match("^Where is what%? Features that (.-) might contain")
    if a then inList, listArea = true, a
    elseif t:match("^When you do find") then inList = false
    elseif inList and t ~= "" then
      for f in t:gmatch("%S+") do features[#features + 1] = f:lower() end
    end
    local what, dirs = t:match("^You sense that (.-) may be located (.-)%.?$")
    if what then answers[#answers + 1] = { feature = what:lower(), dirs = dirs } end
  end
  return listArea or area, features, answers
end

M.addBlockReader("where_is", "*", function(b)
  local area = M.areaNow()
  local listArea, features, answers = M.readWhere(b.lines, area)
  if #features > 0 and listArea then
    for _, f in ipairs(features) do
      M.dbx("INSERT OR IGNORE INTO where_features (area, feature) VALUES (%s, %s)", listArea, f)
    end
  end
  for _, a in ipairs(answers) do
    local here = M.mapRoom
    local room = here and M.followDirs(here, a.dirs)
    M.dbx("INSERT OR REPLACE INTO where_rooms (area, feature, room, start, dirs, t) VALUES (%s, %s, %s, %s, %s, %s)",
      area or listArea or "", a.feature, room, here, a.dirs, os.time())
    if room then pcall(M.mapLearned) end
    M.noteAuto("where", room, a.feature .. (room and "" or " (directions go off the map)"))
  end
end)

-- where a feature is, from what Oven has learned: rows of { area, feature, room }
function M.whereRooms(q)
  q = (q or ""):lower()
  return M.dbRows("SELECT area, feature, room FROM where_rooms WHERE room IS NOT NULL AND (feature = %s OR instr(feature, %s) = 1)", q, q)
end

-- the areas whose feature list has it
function M.whereAreas(q)
  q = (q or ""):lower()
  local out = {}
  for _, r in ipairs(M.dbRows("SELECT DISTINCT area FROM where_features WHERE feature = %s OR instr(feature, %s) = 1", q, q)) do
    out[#out + 1] = r.area
  end
  return out
end

-- sbo go {feature} when Oven doesn't know the room yet: ask the game here (it only answers about this
-- area), then walk there; in another area that has it, walk to that area first and ask on arrival
function M.whereGo(q)
  q = trim(q or ""):lower()
  local area = M.areaNow()
  local areas = M.whereAreas(q)
  local hereHas = false
  for _, a in ipairs(areas) do if area and a:lower() == area:lower() then hereHas = true end end
  if hereHas or #areas == 0 then
    if M.busyWhy(M.lastStatusPrompt) then return false end
    M.quietly("where is " .. q, "where", function()
      local r = M.dbRow("SELECT room, dirs FROM where_rooms WHERE area = %s AND feature = %s", area or "", q)
      if r and tonumber(r.room) then
        M.say("where is " .. q .. ": " .. ((roomExists(tonumber(r.room)) and getRoomName(tonumber(r.room))) or "") .. " #" .. r.room)
        M.mapWalkTo(tonumber(r.room))
      elseif r and r.dirs then
        M.say("where is " .. q .. ": " .. r.dirs .. " (off the map - letting the game lead: where is " .. q .. " track)")
        M.sendOwn("where is " .. q .. " track", false)
      else
        M.say("the game doesn't know a '" .. q .. "' in " .. (area or "this area"))
      end
    end)
    return true
  end
  -- another area has it: walk to the nearest room there, then ask
  local best, bestSteps
  local okA, areaTable = pcall(getAreaTable)
  for _, a in ipairs(areas) do
    local aid = okA and type(areaTable) == "table" and areaTable[a]
    local okR, rooms = pcall(getAreaRooms, aid)
    if aid and okR and type(rooms) == "table" then
      local n = 0
      for _, rid in pairs(rooms) do
        n = n + 1
        if n > 60 then break end
        if M.mapRoom and getPath(M.mapRoom, rid) and (not bestSteps or #speedWalkDir < bestSteps) then best, bestSteps = rid, #speedWalkDir end
      end
    end
  end
  if not best then
    M.say("'" .. q .. "' is in " .. table.concat(areas, ", ") .. " - Oven has no route there on the map")
    return true
  end
  M.say(string.format("'%s' is in %s: walking there, then asking the game", q, table.concat(areas, ", ")))
  M.whereAfterWalk = q
  M.mapWalkTo(best)
  return true
end

-- learning an area by itself: its feature list once, then where each one is - one question at a time,
-- only while you're idle and not walking, fighting or busy, and only while you're still in that area
function M.whereLearnTick()
  if M.cfg.whereLearn == false then return end
  local area = M.areaNow()
  if not area or area == "" then return end
  local p = M.lastStatusPrompt
  if M.busyWhy(p) or not M.userIdle(3) then return end
  local list = M.dbRows("SELECT feature FROM where_features WHERE area = %s", area)
  if #list == 0 then
    M.whereAsked = M.whereAsked or {}
    if M.whereAsked[area .. "|"] then return end
    M.whereAsked[area .. "|"] = os.time()
    M.noteAuto("where", M.mapRoom, "asking for " .. area .. "'s features")
    return M.quietly("where is", "where", function() end)
  end
  M.whereAsked = M.whereAsked or {}
  for _, r in ipairs(list) do
    local f = r.feature
    if not M.dbRow("SELECT feature FROM where_rooms WHERE area = %s AND feature = %s", area, f)
       and not M.whereAsked[area .. "|" .. f] then
      M.whereAsked[area .. "|" .. f] = os.time()
      return M.quietly("where is " .. f, "where", function() end)
    end
  end
end

function M.whereLearnStart()
  if M.whereTimer then killTimer(M.whereTimer) end
  M.whereTimer = tempTimer(4, function() pcall(M.whereLearnTick) end, true)   -- repeating
end

-- sbo shops [text]: the shops Oven knows, or where to buy something (cheapest first)
function M.shopLines(width, q)
  q = trim(q or ""):lower()
  local out, links = {}, {}
  local function where(room)
    local nm = (room and roomExists(room) and getRoomName(room)) or "?"
    local area = room and roomExists(room) and getRoomArea(room)
    area = area and getRoomAreaName(area) or ""
    return nm .. (area ~= "" and (" · " .. area) or "") .. "  #" .. tostring(room)
  end
  local function walkLink(room, label)
    if room and roomExists(room) then links[#links + 1] = { label, function() M.mapWalkTo(room) end } end
  end
  if q == "" then
    local rows = M.dbRows([[SELECT s.room, s.name, s.last, COUNT(i.item) AS n FROM shops s
      LEFT JOIN shop_items i ON i.room = s.room GROUP BY s.room ORDER BY s.name]])
    out[1] = header("map", "", width, string.format("Shops  (%d)", #rows))
    if #rows == 0 then out[#out + 1] = { { C.dim, "  none yet - type shop list at a shopkeeper and Oven keeps it" } } end
    for _, r in ipairs(rows) do
      local room = tonumber(r.room)
      out[#out + 1] = { { C.item, "  " .. (r.name or "a shop") }, { C.num, "  " .. r.n .. " items" }, { C.dim, r.last and ("  listed " .. M.shortDur(os.time() - tonumber(r.last)) .. " ago") or "" } }
      out[#out + 1] = { { C.dim, "    " .. where(room) } }
      walkLink(room, "walk to " .. (r.name or "#" .. room))
    end
    local travelers = M.dbRows([[SELECT key, MAX(text) AS text, COUNT(DISTINCT room) AS n, MAX(last) AS last FROM room_npcs
      WHERE instr(lower(ifnull(tags, '')), 'shop') > 0 GROUP BY key HAVING COUNT(DISTINCT room) >= 2 ORDER BY text]])
    if #travelers > 0 then
      out[#out + 1] = {}
      subhead(out, "Traveling sellers")
      for _, tr in ipairs(travelers) do
        local at = M.dbRow("SELECT room FROM room_npcs WHERE key = %s ORDER BY last DESC LIMIT 1", tr.key)
        local room = at and tonumber(at.room)
        -- a word to find it by: the description's last long word ("hurdy-gurdy")
        local word = tr.text:lower():gsub("[%.!]+$", "")
        local pick = ""
        for w in word:gmatch("[%a%-']+") do if #w >= #pick then pick = w end end
        out[#out + 1] = { { C.text, "  " .. tr.text }, { C.dim, "  · seen in " .. tr.n .. " rooms" } }
        out[#out + 1] = { { C.dim, "    → " }, { C.key, "sbo map highlight " .. pick }, { C.dim, " lights up its path" } }
        if room then
          out[#out + 1] = { { C.dim, "    last seen " .. where(room) .. (tr.last and ("  " .. M.shortDur(os.time() - tonumber(tr.last)) .. " ago") or "") } }
          -- first among the links under the page (before each shop's walk link)
          table.insert(links, 1, { "highlight the path of " .. tr.text:sub(1, 30) .. "…", function() M.mapHighlightAll(pick) end })
          table.insert(links, 2, { "walk to where " .. tr.text:sub(1, 30) .. "… was last seen", function() M.mapWalkTo(room) end })
        end
      end
    end
    local refused = M.dbRows("SELECT room, said, level FROM shop_refusals ORDER BY t DESC")
    if #refused > 0 then
      out[#out + 1] = {}
      subhead(out, "Won't sell to you yet")
      for _, r in ipairs(refused) do
        local room = tonumber(r.room)
        out[#out + 1] = { { C.dim, "  " .. where(room) .. (r.level and ("  (level " .. r.level .. ")") or "") } }
        out[#out + 1] = { { C.dim, "    '" .. tostring(r.said) .. "'" } }
      end
    end
    out[#out + 1] = {}
    out[#out + 1] = { { C.dim, "sbo map shops {item}: who sells it" } }
    return out, links
  end
  local rows = M.dbRows([[SELECT i.room, i.item, i.level, i.amount, i.cost, ifnull(i.currency, 'gold') AS currency, s.name
    FROM shop_items i LEFT JOIN shops s ON s.room = i.room WHERE instr(lower(i.item), %s) > 0
    ORDER BY (ifnull(i.currency, 'gold') <> 'gold'), ifnull(i.currency, 'gold'), i.cost, i.item LIMIT 60]], q)
  out[1] = header("map", "", width, string.format("Shops selling '%s'  (%d)", q, #rows))
  if #rows == 0 then out[#out + 1] = { { C.dim, "  no shop Oven has seen sells that" } } end
  local iw = 0
  for _, r in ipairs(rows) do iw = math.max(iw, math.min(44, ulen(r.item))) end
  for _, r in ipairs(rows) do
    local room = tonumber(r.room)
    out[#out + 1] = { { C.item, "  " .. pad(r.item, iw + 2) }, { C.num, string.format("%11s ", M.commaNum(tonumber(r.cost) or 0)) },
                      { C.dim, pad(r.currency or "gold", 5) },
                      { C.dim, string.format("  lvl %s  ·  %s", r.level or "?", r.amount == "No limit" and "no limit" or (tostring(r.amount) .. " left")) } }
    out[#out + 1] = { { C.dim, "    " .. (r.name or "a shop") .. " · " .. where(room) } }
    walkLink(room, "walk to " .. (r.name or "#" .. room) .. " (" .. r.item .. ")")
  end
  return out, links
end

-- a quest the game hands you without a command (the daily quest at login):
-- "You undertake the quest 'Daily Quest - Feeding Hungry Mouths', #3519." then the quest in full
-- …or any quest that arrives in full after a command that isn't a quest command ("use card spaghetti and
-- pesto": "This quest [3390] is called 'Cooking Spaghetti and Pesto', …"): a quest you were just given
M.addBlockReader("quest_undertaken", "*", function(b)
  -- the reply to a quest command (quest info 3390) is read by its own capture
  for _, c in ipairs(b.cmds or {}) do if M.classify(c) == "quest" then return end end
  for i, l in ipairs(b.lines) do
    local t = trim(l)
    local undertake = t:match("^You undertake the quest '.-', #%d+%.?$")
    if undertake or t:match("^This quest %[%d+%] is called '") then
      local rest, restD = {}, {}
      for j = undertake and (i + 1) or i, #b.lines - (b.prompt and 1 or 0) do
        rest[#rest + 1] = b.lines[j]; restD[#rest] = (b.decho or {})[j]
      end
      local q = M.parseQuests(rest, restD)
      if q.detail and q.detail.id then
        M.questReplyRequest = true
        M.rememberQuests({ list = {}, detail = q.detail }, false)
        M.questReplyRequest = nil
        -- something else may have changed at the same time (a quest finished that handed you this one):
        -- check the quest log quietly
        tempTimer(1.5, function() pcall(M.questLogCheck) end)
      end
      return
    end
  end
end)

-- a quiet "quest info": the quest panel catches up (finished quests come off it)
function M.questLogCheck()
  if M.busyWhy(M.lastStatusPrompt) then return end
  M.quietQuest = true
  M.sendOwn("quest info", false)
end

-- who's here, tagged: saved to the room
M.addBlockReader("room_npcs", "room", function(b, seg)
  local seen = {}
  for _, x in ipairs(seg.here) do
    local tags, text = M.npcTags(x)
    if tags and not seen[text:lower()] then
      local key = text:lower()
      seen[key] = true
      local tg = table.concat(tags, ",")
      local have = M.dbRow("SELECT seen FROM room_npcs WHERE room = %s AND key = %s", seg.room, key)
      if have then
        M.dbx("UPDATE room_npcs SET tags = %s, seen = seen + 1, last = %s, src = 'room' WHERE room = %s AND key = %s", tg, os.time(), seg.room, key)
      else
        local c = M.dbRow("SELECT COUNT(*) AS c FROM room_npcs WHERE room = %s", seg.room)
        if tonumber(c and c.c or 0) < 20 then
          M.dbx("INSERT INTO room_npcs (room, key, text, tags, seen, last, src) VALUES (%s, %s, %s, %s, 1, %s, 'room')", seg.room, key, text, tg, os.time())
          pcall(M.mapLearned)
        end
      end
    end
  end
end)

-- a shop on your first visit: its keeper's [Shop] tag is only known once the room's text has been read,
-- after GMCP's arrival check (which catches the shops Oven already knew). Ask now, while you're still there.
M.addBlockReader("shop_first_visit", "room", function(b, seg)
  local room = seg.room
  if not room or room ~= M.mapRoom then return end
  local tagged = false
  for _, x in ipairs(seg.here) do
    local tags, text = M.npcTags(x)
    for _, t in ipairs(tags or {}) do
      if t:lower() == "shop" and not M.isTraveler(text:lower()) then tagged = true end
    end
  end
  if not tagged then return end
  if M.dbRow("SELECT room FROM shops WHERE room = %s", room) then return end
  if M.shopTried[room] and os.time() - M.shopTried[room] < 3600 then return end   -- asked on arrival already
  local p = M.lastStatusPrompt or b.lines[#b.lines]
  tempTimer(0, function()
    local ok, err = pcall(M.shopAutoList, room, p)
    if not ok then M.noteAuto("shop", room, "error: " .. tostring(err)) end
  end)
end)

-- playing, not logging in: the line is your status prompt (<291hp 696sp 457st>), and GMCP says so -
-- char.status "playing", or, since the game sends char.status rarely (some logins not at all), your room
-- over GMCP. The login screen has neither a status prompt nor a room, so nothing is sent at a password prompt.
function M.inGame(promptLine)
  if promptLine == nil or #M.parsePrompt(promptLine).vals == 0 then return false end
  local st = M.gmcpGet and M.gmcpGet("char.status")
  if type(st) == "table" and st.state ~= nil then return st.state == "playing" end
  local room = M.gmcpGet and M.gmcpGet("room.info")
  return type(room) == "table" and tonumber(room.num) ~= nil
end

-- "Currently defined aliases:" / " 1. 'pp' performs action 'cast 'pressure points''" / "A total of 3/100 aliases."
-- "You have aliased 'lp' to perform action 'cast lightning'."
-- "Alias 'lp' has been realiased to 'cast 'lightning pursuit'' from 'cast lightning pursuit''."
function M.readAliases(lines)
  local list, inList, changed = nil, false, false
  M.cfg.gameAliases = M.cfg.gameAliases or {}
  for _, l in ipairs(lines) do
    local t = trim(l)
    if t:match("^Currently defined aliases:?$") then list, inList = {}, true
    elseif inList and t:match("^A total of %d+/%d+ aliases?%.?$") then
      M.cfg.gameAliases, inList, changed = list, false, true
    elseif inList then
      local name, action = t:match("^%d+%. '(%S+)' performs action '(.*)'$")
      if name then list[name:lower()] = action end
    else
      local name, action = t:match("^You have aliased '(%S+)' to perform action '(.*)'%.$")
      if not name then name, action = t:match("^Alias '(%S+)' has been realiased to '(.*)' from '.*'%.$") end
      if name then M.cfg.gameAliases[name:lower()] = action; changed = true end
    end
  end
  -- "You have no aliases defined." and the like: a list with nothing in it
  if inList and list then M.cfg.gameAliases, changed = list, true end
  if changed then M.aliasesRead = true; M.saveSettings() end
  return changed
end

M.addBlockReader("aliases", "*", function(b, kinds)
  if kinds.help then return end
  M.readAliases(b.lines)
  -- unalias: the game's answer isn't known to Oven, so read the list again afterwards
  for _, c in ipairs(b.cmds or {}) do
    if c:lower():match("^%s*unalias%s") then
      tempTimer(0.5, function() M.quietly("alias", "aliases", function(l) if l then M.readAliases(l) end end) end)
    end
  end
  -- once per session, quietly - but only once you're in the game: never at the login screen, where a
  -- "Password:" question looks like a prompt and anything sent would be taken as your password.
  -- In the game = GMCP says you're playing and this prompt carries your status (<291hp ...>).
  if b.prompt and not M.aliasesRead and not M.aliasesAsked and M.inGame(b.lines[#b.lines]) then
    M.aliasesAsked = true
    tempTimer(1, function() M.quietly("alias", "aliases", function(l) if l then M.readAliases(l) end end) end)
  end
end)

---------------------------------------------------------------------------
-- Chat: channel talk, tells and says, gathered into the Chat tab with a row of channel chips
-- (All · CLAN 2 · Tells…). Channels are learned as they appear - nothing is listed in advance.
-- Lines keep the game's colours; the main screen is left as it is.
---------------------------------------------------------------------------
M.chat = M.chat or { lines = {}, unread = {}, filter = "All" }
local CHAT_KEEP = 500

-- recognisers: a line -> channel, who, message (nil if it isn't chat). Add more with M.addChatPattern.
M.chatPatterns = {}
function M.addChatPattern(name, find) M.chatPatterns[#M.chatPatterns + 1] = { name = name, find = find } end

local function knownChannel(tag)
  for _, c in ipairs(M.cfg.chatChannels or {}) do if c == tag then return true end end
  -- the game's own list (from the channel command): CLAN, SHOUT, NOVICETALK...
  local g = M.cfg.chatGameChannels or {}
  return g[tag] ~= nil or (tag == "NOVICE" and g.NOVICETALK ~= nil)
end

-- "[CLAN] Yakumo: 'sup nac'"  - a channel: a tag of letters, one name, then the message in quotes
M.addChatPattern("channel", function(l)
  local tag, who, msg = l:match("^%[(%a[%a ]-)%] (%u[%w%-']*): '(.*)'%s*$")
  if tag then return tag, who, msg end
end)
-- "[CLAN] Roarke has been slain in A Fetid Lane!" - news on a channel already seen talking
M.addChatPattern("notice", function(l)
  local tag, rest = l:match("^%[(%u[%u ]-)%] (%u.+)$")
  if tag and knownChannel(tag) then return tag, nil, rest end
end)
-- channels that come as a sentence: "A voice yells 'The ship Merdraco be docked at Rune!'",
-- "A sepulchral voice announces, 'X has been enrolled in Clan Megaleios!'", "Name shouts '...'"
local SPOKEN = { yells = "YELL", shouts = "SHOUT", announces = "ANNOUNCEMENT" }
M.addChatPattern("spoken", function(l)
  local who, verb, msg = l:match("^(%u[^']-) (%l+),? '(.*)'%s*$")
  if who and SPOKEN[verb] then return SPOKEN[verb], who, msg end
end)
-- "Local Hint: ...", "Personalized Hint: ..."
M.addChatPattern("hint", function(l)
  local kind, msg = l:match("^(%u%l+ Hint): (.+)$")
  if kind then return "HINT", kind, msg end
end)
-- quest givers Oven knows (from quest info and "Return to X ..."): NPCs, even with one-word names
local function questGiver(who)
  who = who:lower()
  for _, Q in pairs(M.quests or {}) do
    for _, k in ipairs({ "master", "turnIn" }) do   -- (either may be missing)
      local n = Q[k]
      if n and (n:lower() == who or n:lower():gsub("^the ", "") == who) then return true end
    end
  end
end
M.questGiver = questGiver

-- tells, to and from you. Several-word names ("An old druid tells you") are creatures, not players.
M.addChatPattern("tell", function(l)
  local who, msg = l:match("^(%u[%w%-']*) tells you,? '(.*)'%s*$")
  if who then
    if questGiver(who) then return end
    return "Tells", who, msg
  end
  who, msg = l:match("^You tell (%u[%w%-']*),? '(.*)'%s*$")
  if who then return "Tells", "you → " .. who, msg end
end)
-- says, from players (one-word names) and you
M.addChatPattern("say", function(l)
  local who, msg = l:match("^(%u[%w%-']*) says?, '(.*)'%s*$")
  if who and who ~= "You" and not questGiver(who) then return "Say", who, msg end
  msg = l:match("^You say,? '(.*)'%s*$")
  if msg then return "Say", "you", msg end
end)

function M.chatFind(l)
  if not l:find("'", 1, true) and not l:match("^%[%u") and not l:find(" Hint: ", 1, true) then return end
  for _, p in ipairs(M.chatPatterns) do
    local ok, ch, who, msg = pcall(p.find, l)
    if ok and ch then return ch, who, msg end
  end
end

-- the channel command: "Your current channel settings:" then "CLAN            is ON."
M.addBlockReader("chat_channels", "*", function(b, kinds)
  if kinds.help then return end
  local found
  for _, l in ipairs(b.lines) do
    if l:match("^Your current channel settings:") then found = {}
    elseif found then
      local name, on = l:match("^(%u+)%s+is (%u+)%.%s*$")
      if name then found[name] = (on == "ON") end
    end
  end
  if found and next(found) then M.cfg.chatGameChannels = found; M.saveSettings() end
end)

-- chat in a block: every line but the prompt, never inside a help page
M.addBlockReader("chat", "*", function(b, kinds)
  if kinds.help then return end
  local last = #b.lines - (b.prompt and 1 or 0)
  for i = 1, last do
    local l = b.lines[i]
    local ch, who, msg = M.chatFind(l)
    if ch then M.chatAdd(ch, l, b.decho and b.decho[i], b.t, who, msg) end
  end
end)

function M.chatAdd(ch, plain, decho, t, who, msg)
  local C = M.chat
  M.cfg.chatChannels = M.cfg.chatChannels or {}
  local listed = false
  for _, c in ipairs(M.cfg.chatChannels) do if c == ch then listed = true; break end end
  if not listed then
    table.insert(M.cfg.chatChannels, ch)
    M.saveSettings()
  end
  local e = { ch = ch, plain = plain, decho = decho, t = t or os.time(), who = who, msg = msg }
  C.lines[#C.lines + 1] = e
  while #C.lines > CHAT_KEEP do table.remove(C.lines, 1) end
  local muted = (M.cfg.chatMuted or {})[ch]
  local seen = M.tabOn == "chat" and M.container and (C.filter == "All" or C.filter == ch)
  if not muted and not seen then C.unread[ch] = (C.unread[ch] or 0) + 1 end
  if M.chatConsole and (C.filter == "All" and not muted or C.filter == ch) then M.chatEcho(e) end
  pcall(M.chatChips)
end

local function chatLine(e)
  local d = e.decho or ("<192,192,192>" .. e.plain)
  return "<90,90,100>" .. os.date("%H:%M", e.t) .. " " .. d
end
function M.chatEcho(e)
  pcall(function() M.chatConsole:decho(chatLine(e) .. "\n") end)
end

-- redraw the console for the chosen chip
function M.chatRender()
  if not M.chatConsole then return end
  local C, muted = M.chat, M.cfg.chatMuted or {}
  pcall(function() M.chatConsole:clear() end)
  local any = false
  for _, e in ipairs(C.lines) do
    if (C.filter == "All" and not muted[e.ch]) or C.filter == e.ch then M.chatEcho(e); any = true end
  end
  if not any then
    pcall(function() M.chatConsole:decho("<90,90,100>" .. (#C.lines == 0
      and "Channel talk, tells and says collect here as they happen - each channel gets its own chip above."
      or "Nothing on " .. C.filter .. " yet.") .. "\n") end)
  end
end

local chipStyle = [[QLabel { color: %s; background-color: %s; border: 1px solid %s; border-radius: 9px;
  padding: 0 8px; margin: 2px 2px; %s } QLabel::hover { color: #ffffff; }]]
local function chipCss(on, muted, hot)
  if muted then return string.format(chipStyle, "#555555", "rgba(0,0,0,0)", "#2a2a2a", "text-decoration: line-through;") end
  if on then return string.format(chipStyle, "#e6c35c", "rgba(40,36,20,255)", "#8a7430", "") end
  return string.format(chipStyle, hot and "#e0e0e0" or "#909090", "rgba(24,24,32,255)", "#333333", "")
end

-- chips: All, then each channel in the order it first spoke; counts are unread lines
function M.chatChips()
  if not M.chatBar then return end
  local C, muted = M.chat, M.cfg.chatMuted or {}
  local names = { "All" }
  for _, c in ipairs(M.cfg.chatChannels or {}) do names[#names + 1] = c end
  local total = 0
  for ch, n in pairs(C.unread) do if not muted[ch] then total = total + n end end
  M.chatChipLabels = M.chatChipLabels or {}
  local relayout = false
  for i, name in ipairs(names) do
    local n = name == "All" and total or (C.unread[name] or 0)
    local text = name .. ((n > 0) and (" " .. n) or "")
    local w = math.max(44, 22 + 8 * ulen(text))
    local lab = M.chatChipLabels[i]
    if not lab then
      lab = Geyser.Label:new({ name = "ovenChatChip" .. i, width = w, h_policy = Geyser.Fixed }, M.chatBar)
      pcall(function() lab:setCursor("PointingHand") end)
      M.chatChipLabels[i] = lab
      relayout = true
    elseif lab.chipW ~= w then
      pcall(function() lab:resize(w, lab.get_height and lab:get_height() or 24) end)
      relayout = true
    end
    lab.chipW = w
    lab:echo("<center>" .. (text:gsub("&", "&amp;"):gsub("<", "&lt;")) .. "</center>")
    lab:setStyleSheet(chipCss(C.filter == name, muted[name], n > 0))
    pcall(function() lab:setToolTip(name == "All" and "every channel that isn't muted"
      or ("only " .. name .. " - right-click to " .. (muted[name] and "unmute" or "mute"))) end)
    lab:setClickCallback(function(ev)
      if type(ev) == "table" and ev.button == "RightButton" and name ~= "All" then return M.chatMute(name) end
      M.chatFilter(name)
    end)
    lab:show()
  end
  for i = #names + 1, #M.chatChipLabels do M.chatChipLabels[i]:hide() end
  if relayout and M.chatBar.organize then pcall(function() M.chatBar:organize() end) end
  if M.tabLabels and M.tabLabels.chat then
    M.tabLabels.chat:echo("<center>Chat" .. (total > 0 and (" (" .. total .. ")") or "") .. "</center>")
  end
end

function M.chatSeen()
  local C = M.chat
  if C.filter == "All" then
    local muted = M.cfg.chatMuted or {}
    for ch in pairs(C.unread) do if not muted[ch] then C.unread[ch] = nil end end
  else
    C.unread[C.filter] = nil
  end
  pcall(M.chatChips)
end

function M.chatFilter(name)
  M.chat.filter = name
  M.chatRender()
  M.chatSeen()
end

function M.chatMute(name)
  M.cfg.chatMuted = M.cfg.chatMuted or {}
  M.cfg.chatMuted[name] = (not M.cfg.chatMuted[name]) or nil
  if M.cfg.chatMuted[name] then M.chat.unread[name] = nil end
  M.saveSettings()
  M.chatRender()
  pcall(M.chatChips)
  M.say(name .. (M.cfg.chatMuted[name] and " muted - its lines stay out of All (click its chip to read it)" or " unmuted"))
end

-- the Chat tab: chips over a console
function M.buildChat(page)
  local box = Geyser.VBox:new({ name = "ovenChatBox", x = 0, y = 0, width = "100%", height = "100%" }, page)
  M.chatBar = Geyser.HBox:new({ name = "ovenChatChips", height = 24, v_policy = Geyser.Fixed }, box)
  M.chatChipLabels = {}
  M.chatConsole = Geyser.MiniConsole:new({ name = "ovenChatConsole", color = "black" }, box)
  local font, size = pageFont()
  pcall(function() M.chatConsole:setFont(font) end)
  pcall(function() M.chatConsole:setFontSize(size) end)
  pcall(function() M.chatConsole:enableAutoWrap() end)
  pcall(function() M.chatConsole:enableScrollBar() end)
  M.chatChips()
  M.chatRender()
end

---------------------------------------------------------------------------
-- The Notes tab: notes you keep, each with where you were (click to walk back there). Type one in the
-- box at the bottom and press Enter, or sbo notes add {text}.
---------------------------------------------------------------------------
function M.buildNotes(page)
  local box = Geyser.VBox:new({ name = "ovenNotesBox", x = 0, y = 0, width = "100%", height = "100%" }, page)
  M.notesConsole = Geyser.MiniConsole:new({ name = "ovenNotesConsole", color = "black" }, box)
  local font, size = pageFont()
  pcall(function() M.notesConsole:setFont(font) end)
  pcall(function() M.notesConsole:setFontSize(size) end)
  pcall(function() M.notesConsole:enableAutoWrap() end)
  pcall(function() M.notesConsole:enableScrollBar() end)
  M.notesInput = Geyser.CommandLine:new({ name = "ovenNotesInput", height = 26, v_policy = Geyser.Fixed }, box)
  pcall(function() M.notesInput:setStyleSheet([[
    background-color: rgba(24,24,32,255); color: #d0d0d0; border: 1px solid #333;
    qproperty-placeholderText: "write a note and press Enter - it's kept with the room you're in";]]) end)
  M.notesInput:setAction(function(text)
    pcall(function() M.notesInput:clear() end)
    M.noteAdd(text)
  end)
  M.notesRender()
end

function M.noteAdd(text)
  text = trim(text or "")
  if text == "" then return end
  local room = M.mapRoom
  local name = room and roomExists(room) and getRoomName(room) or nil
  M.dbx("INSERT INTO notes (t, text, room, room_name, area) VALUES (%s, %s, %s, %s, %s)", os.time(), text, room, name, M.areaNow())
  local r = M.dbRow("SELECT MAX(id) AS id FROM notes")
  M.notesRender()
  M.say("note #" .. tostring(r and r.id) .. " kept" .. (name and (" (at " .. name .. ")") or ""))
end

function M.noteRemove(n)
  n = tonumber(n)
  if not n or not M.dbRow("SELECT id FROM notes WHERE id = %s", n) then return M.say("no note #" .. tostring(n)) end
  M.dbx("DELETE FROM notes WHERE id = %s", n)
  M.notesRender(M.notesFilter)
  M.say("note #" .. n .. " removed")
end

local function noteLink(text, fn, hint)
  local ok = pcall(function() M.notesConsole:dechoLink(text, fn, hint, true) end)
  if not ok then pcall(function() M.notesConsole:decho(text) end) end
end

function M.notesRender(filter)
  M.notesFilter = (filter and filter ~= "") and filter or nil
  if not M.notesConsole then return end
  pcall(function() M.notesConsole:clear() end)
  local q = M.notesFilter and M.notesFilter:lower() or ""
  local rows = M.dbRows([[SELECT id, t, text, room, room_name, area FROM notes
    WHERE %s = '' OR instr(lower(text || ' ' || ifnull(room_name, '') || ' ' || ifnull(area, '')), %s) > 0 ORDER BY id]], q, q)
  local con = M.notesConsole
  if M.notesFilter then
    pcall(function() con:decho(string.format("<230,195,92>notes with '%s'  <90,90,100>(%d)  ", M.notesFilter, #rows)) end)
    noteLink("<135,206,250>show all", function() M.notesRender() end, "every note")
    pcall(function() con:decho("\n\n") end)
  end
  if #rows == 0 then
    pcall(function() con:decho("<90,90,100>" .. (M.notesFilter and "No note has that in it." or
      "Your notes go here, kept for good. Type one in the box below and press Enter - it remembers the room you're in, so you can walk back to it.") .. "\n") end)
    return
  end
  for _, r in ipairs(rows) do
    local id, room = tonumber(r.id), tonumber(r.room)
    local where = {}
    if r.room_name then where[#where + 1] = r.room_name end
    if r.area and r.area ~= "" then where[#where + 1] = r.area end
    pcall(function() con:decho(string.format("<90,90,100>#%d  %s%s  ", id, os.date("%Y-%m-%d %H:%M", tonumber(r.t) or 0),
      #where > 0 and ("  ·  " .. table.concat(where, " · ")) or "")) end)
    if room then
      noteLink("<135,206,250>[go]", function() M.mapWalkTo(room) end, "walk to " .. (r.room_name or ("#" .. room)))
      pcall(function() con:decho(" ") end)
    end
    noteLink("<120,120,130>[delete]", function() M.noteRemove(id) end, "remove note #" .. id)
    pcall(function() con:decho("\n<215,215,215>" .. tostring(r.text):gsub("<", "&lt;") .. "\n\n") end)
  end
end

function M.notesShow(filter)
  M.createWindow(); M.container:show()
  if M.cfg.tabs then M.tabShow("notes") end
  M.notesRender(filter)
end

function M.chatCommand(b)
  local a, rest = b:match("^(%S*)%s*(.-)$")
  a = a:lower()
  local function find(n)
    if n:lower() == "all" then return "All" end
    for _, c in ipairs(M.cfg.chatChannels or {}) do if c:lower() == n:lower() then return c end end
  end
  if a == "" then
    M.createWindow(); M.container:show(); M.tabShow("chat"); return
  elseif a == "mute" or a == "unmute" then
    local c = find(rest)
    if not c or c == "All" then return M.say("no channel called '" .. rest .. "' yet - channels: " .. table.concat(M.cfg.chatChannels or {}, ", ")) end
    if (a == "mute") ~= ((M.cfg.chatMuted or {})[c] == true) then M.chatMute(c) end
    return
  elseif a == "clear" then
    M.chat.lines, M.chat.unread = {}, {}
    M.chatRender(); pcall(M.chatChips)
    return M.say("chat cleared")
  elseif a == "forget" then
    local c = find(rest)
    if not c or c == "All" then return M.say("no channel called '" .. rest .. "'") end
    for i, x in ipairs(M.cfg.chatChannels) do if x == c then table.remove(M.cfg.chatChannels, i); break end end
    M.chat.unread[c] = nil
    if M.chat.filter == c then M.chat.filter = "All" end
    M.saveSettings(); M.chatRender(); pcall(M.chatChips)
    return M.say(c .. " forgotten (it comes back if it's used again)")
  end
  local c = find(b)
  if c then M.createWindow(); M.container:show(); M.tabShow("chat"); return M.chatFilter(c) end
  M.say("sbo chat [channel|all] · sbo chat mute|unmute <channel> · sbo chat clear · sbo chat remove <channel>")
end

-- what the game sends over GMCP right now, written in full to oven_gmcp.txt
function M.gmcpDump()
  local pk = M.gmcpPackages()
  local names = {}
  for name in pairs(pk) do names[#names + 1] = name end
  table.sort(names)
  local f = io.open(getMudletHomeDir() .. "/oven_gmcp.txt", "w")
  if f then
    f:write("-- GMCP at " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    for _, name in ipairs(names) do f:write(name .. " = " .. pk[name] .. "\n") end
    f:close()
  end
  return names
end

-- "<281hp 696sp 444st> You receive…" -> "<281hp 696sp 444st> " (a status prompt at the start of a longer line)
function M.promptHead(l)
  local from = 1
  for _ = 1, 4 do
    local i = l:find(">", from, true)
    if not i or i > 90 then return nil end
    local head = l:sub(1, i)
    if l:sub(i + 1):match("%S") and #M.parsePrompt(head).vals > 0 then return head end
    from = i + 1
  end
end

-- every game line: the work is in onLineWork; while it runs, Oven's own messages wait (see M.log)
function M.onLine()
  M.inLine = true
  local ok, err = pcall(M.onLineWork)
  M.inLine = false
  if not ok then error(err, 0) end
end

function M.onLineWork()
  local cap = M.cap
  pcall(M.observe, line)
  pcall(M.recordLine, line, isPromptLine())
  if isPromptLine() and #M.parsePrompt(line).vals > 0 then M.lastStatusPrompt = line end
  pcall(M.noteRoomLine, line)
  pcall(M.noteKillContext, line)
  -- "(Mount: 764st)": your mount's stamina, sent just before each prompt while riding.
  -- It goes on the bar; it's never part of a command's output.
  pcall(M.noteLootContext, line)
  if line:find("^%s*The Powers take pity on you and restore your soul to your body") then
    M.sess.deathsLive = (M.sess.deathsLive or 0) + 1
    pcall(M.noteRoomDeath)
    pcall(M.drawBar)
  end
  if M.fights and next(M.fights) then pcall(M.noteFightEnd, line) end
  local doneQuest = line:match("^%s*All parts of your quest '(.+)' are complete%.?%s*$")
  -- "You inform Lord Agrippa you have completed your quest 'Jail Time'." - turned in
  local turnedIn = not doneQuest and line:match("^%s*You inform .- you have completed your quest '(.+)'%.?%s*$")
  if turnedIn then pcall(M.questTurnedIn, turnedIn)
  elseif doneQuest then pcall(M.questMarkComplete, doneQuest)
  else
    -- the line after it: "Return to Lord Agrippa in time to receive your reward!"
    local who = M.questJustDone and line:match("^%s*Return to (.-) in time to receive your reward")
    if who then
      local id = M.questJustDone
      local Q = M.quests[id]
      M.questJustDone = nil
      if Q then
        Q.turnIn = who
        M.cfg.quests = M.quests; M.saveSettings()
        pcall(M.drawQuestTracker)
        if (M.cfg.questPins or {})[id] then M.notifyQuest((Q.name or ("#" .. id)) .. " complete - return to " .. who .. " for your reward") end
      end
    elseif trim(line) ~= "" then
      M.questJustDone = nil
      pcall(M.noteQuestProgress, line)
    end
  end
  -- sbo mirror chat off: chat goes to the Chat tab only (while the window is there to show it)
  if M.cfg.mirror.chat == false and not cap and M.cfg.tabs and M.cfg.window and M.container
      and not isPromptLine() and M.chatFind(line) then
    deleteLine()
    return
  end
  local mount = line:match("^%s*%(Mount:%s*(%d+)%s*st%)%s*$")
  if mount then
    M.mountPending = tonumber(mount)
    if M.cfg.bar then deleteLine() end
    return
  end
  if not cap and not M.cfg.bar then return end
  -- the game's pager: "[C]ontinue [R]edraw [B]ack [E]xit:"
  if line:match("^%s*%[C%]ontinue") then
    if cap and cap.kind == "help" and (cap.pages or 1) < 30 then
      -- keep reading the help page into the window: answer the pager ourselves
      cap.pages = (cap.pages or 1) + 1
      if cap.gag then deleteLine() end
      if cap.maxTimer then killTimer(cap.maxTimer) end
      cap.maxTimer = tempTimer(M.cfg.maxTime + 3, function() M.finish("maxtime") end)
      -- the next page needs a round trip to the game: don't let the short
      -- "no more text" timer close the page while we wait for it
      if cap.idleTimer then killTimer(cap.idleTimer) end
      cap.idleTimer = tempTimer(3, function() M.finish("idle") end)
      M.sendOwn("c", false)
    end
    return   -- otherwise leave it in the main window so you can answer it
  end
  -- the game went on straight after a prompt, on the same line ("<281hp 696sp 444st> You receive an index
  -- card containing a recipe."): the prompt part goes to the bar, the rest stays as the game's text
  local head = M.cfg.bar and M.promptHead(line)
  if head then
    do
      local n = #head + #(line:sub(#head + 1):match("^%s*"))
      if selectSection(0, n) then
        local okd, d = pcall(copy2decho)
        replace("")
        deselect()
        M.lastStatusPrompt = head
        pcall(M.barUpdate, okd and d or head)
      end
    end
    if cap and #cap.plain > 0 then M.finish("prompt") end   -- it was the prompt that ended a reply
  end
  if not head and isPromptLine() then
    if cap and #cap.plain > 0 then M.finish("prompt") end
    -- a question the game asks the way it sends a prompt ("Do you really want to quit (y/N)?") isn't
    -- your status: it stays in the game text to be answered. Your prompt has values (<291hp ...>).
    local status = #M.parsePrompt(line).vals > 0
    if status then M.promptHasVals = true end
    if M.cfg.bar and (status or not M.promptHasVals) then
      local d = selectionDecho() or line
      if not promptLogged then
        promptLogged = true
        if M.cfg.samples then
          local f = io.open(M.samplesFile, "a")
          if f then f:write("===== " .. os.date("%Y-%m-%d %H:%M:%S") .. " | kind=prompt | cmd=\n" .. line .. "\n===== end\n\n"); f:close() end
        end
      end
      M.barUpdate(d)
      M.dropBlankAbove()   -- the blank line the game sends before each prompt
      deleteLine()
      moveCursorEnd()
    end
    return
  end
  if not cap then return end
  -- a help page is over once its SEE ALSO list has ended: whatever comes after a blank line that
  -- isn't another link (the next step of an auto-run, before any prompt) is the game going on
  if cap.kind == "help" then
    local t = trim(line)
    if cap.seeAlso and cap.afterBlank and t ~= "" and not line:match("^%s+%[%s*%d+%s*%]") then
      M.finish("help-end")
      return
    end
    if t:match("^SEE ALSO:?$") then cap.seeAlso = true end
    cap.afterBlank = cap.seeAlso and t == "" or false
  end
  if not M.belongs(cap, line) then return end   -- someone else's activity: leave it where it is
  if #cap.plain == 0 and trim(line) == "" then
    if cap.gag then deleteLine() end
    return
  end
  cap.plain[#cap.plain + 1] = line
  cap.decho[#cap.decho + 1] = selectionDecho() or line   -- keeps the game's colours
  if cap.gag then deleteLine() end
  if cap.idleTimer then killTimer(cap.idleTimer) end
  cap.idleTimer = tempTimer(M.cfg.idle, function() M.finish("idle") end)
  if #cap.plain >= (cap.kind == "help" and 2000 or M.cfg.maxLines) then M.finish("maxlines") end
end

local function writeSample(cap)
  local f = io.open(M.samplesFile, "a")
  if not f then return end
  f:write(string.format("===== %s | kind=%s | cmd=%s\n", os.date("%Y-%m-%d %H:%M:%S"), cap.kind, cap.cmd))
  for _, l in ipairs(cap.plain) do f:write(l, "\n") end
  if cap.decho and #cap.decho > 0 then
    f:write("----- with colour codes\n")
    for _, d in ipairs(cap.decho) do f:write(d, "\n") end
  end
  f:write("===== end\n\n")
  f:close()
end

function M.finish(reason)
  local cap = M.cap
  if not cap then return end
  M.cap = nil
  -- the reply to a plain "quest info" (no quest number): every quest you have
  M.questReplyBare = cap.kind == "quest" and tostring(cap.cmd or ""):lower():match("^%s*quest%s+info%s*$") ~= nil
  -- the reply to "quest request" (any abbreviation, "que req"): the quest you were just given;
  -- after "quest complete", check the quest log quietly: a quest that's gone from it was turned in
  do
    local v, a = tostring(cap.cmd or ""):lower():match("^%s*(%a+)%s+(%a+)")
    -- the game takes short forms: "que re", "quest com"
    local isQuest = cap.kind == "quest" and v ~= nil and #v >= 3 and ("quest"):sub(1, #v) == v and #a >= 2
    M.questReplyRequest = isQuest and ("request"):sub(1, #a) == a
    if isQuest and ("complete"):sub(1, #a) == a and not cap.quiet then
      tempTimer(1, function()
        -- the game said so itself ("You inform ... you have completed your quest"): nothing to check
        if M.questTurnedInAt and os.time() - M.questTurnedInAt < 10 then return end
        M.questTurnInCheck = true; M.quietQuest = true; M.sendOwn("quest info", false)
      end)
    end
  end
  if cap.idleTimer then killTimer(cap.idleTimer) end
  if cap.maxTimer then killTimer(cap.maxTimer) end

  -- trim trailing blank lines
  while #cap.plain > 0 and trim(cap.plain[#cap.plain]) == "" do
    table.remove(cap.plain); table.remove(cap.decho)
  end

  -- no telnet GA / pattern match: the last line may be an unrecognised prompt
  local heldPrompt
  if reason ~= "prompt" and #cap.plain > 1 then
    local last = cap.plain[#cap.plain]
    if ulen(last) < 90 and last:match(">%s*$") and not parseSlot(last) then
      table.remove(cap.plain)
      heldPrompt = table.remove(cap.decho) or last
    end
  end

  if #cap.plain == 0 and not heldPrompt and not cap.quiet then
    local nxt = table.remove(M.queue, 1)
    if nxt then M.start(nxt[1], nxt[2], nxt[3]) end
    return
  end

  if cap.quiet and cap.quietKind == "quest" then
    -- tracker refresh: update the quest, draw nothing
    if reason == "prompt" and not M.cfg.bar then deleteLine() end
    local q = M.parseQuests(cap.plain, cap.decho)
    pcall(function() M.rememberQuests(q, M.questReplyBare) end)
    -- after quest complete, a log with no quests at all: every finished pinned quest was turned in
    if M.questTurnInCheck and M.questReplyBare and #q.list == 0 and not q.detail then
      for id in pairs(M.cfg.questPins or {}) do
        local Q = M.quests[id]
        if Q and questFinished(Q) then
          M.cfg.questPins[id] = nil
          Q.active = false
          M.notifyQuest((Q.name or ("#" .. id)) .. " turned in - unpinned")
        end
      end
      M.saveSettings(); pcall(M.drawQuestTracker)
    end
    M.questTurnInCheck = nil
    if M.cfg.samples and #cap.plain > 0 then writeSample(cap) end
    local nxt = table.remove(M.queue, 1)
    if nxt then M.start(nxt[1], nxt[2], nxt[3]) end
    return
  end
  if cap.quiet and cap.quietKind == "fn" then
    -- a reply Oven asked for itself (sbo eq learn carried): hand it over, draw nothing
    if reason == "prompt" and not M.cfg.bar then deleteLine() end
    local fn = cap.quietFn
    pcall(M.updateCarried, cap)
    tempTimer(0.3, function() pcall(fn, cap.plain) end)
    local nxt = table.remove(M.queue, 1)
    if nxt then M.start(nxt[1], nxt[2], nxt[3]) end
    return
  end
  if cap.quiet then
    -- sbo eq learn: remember the item, draw nothing, keep the prompt out of the log too
    if reason == "prompt" and not M.cfg.bar then deleteLine() end
    local ok, it = pcall(M.parseItem, cap.plain)
    local good = ok and it and it.name and true or false
    if good then M.remember(it); M.learnStats.ok = M.learnStats.ok + 1
    else M.learnStats.fail = M.learnStats.fail + 1 end
    if M.cfg.samples and #cap.plain > 0 then writeSample(cap) end
    local entry = M.learning and M.learning.entry
    M.learning = nil
    pcall(M.learnResult, entry, good)
    tempTimer(0.3, function() M.learnNext() end)
    local nxt = table.remove(M.queue, 1)
    if nxt then M.start(nxt[1], nxt[2], nxt[3]) end
    return
  end

  local replace = cap.gag
  if not replace then heldPrompt = nil end
  local promptDecho
  if reason == "prompt" and replace and #cap.plain > 0 and not M.cfg.bar then
    -- hold the prompt back so the formatted text appears above it
    promptDecho = selectionDecho()
    if promptDecho then deleteLine() end
  end

  if #cap.plain > 0 then
    M.history[#M.history + 1] = cap
    if #M.history > 20 then table.remove(M.history, 1) end
    if M.cfg.samples then writeSample(cap) end
  end

  local nonBlank = 0
  for _, l in ipairs(cap.plain) do if trim(l) ~= "" then nonBlank = nonBlank + 1 end end
  local worth = cap.hasLayout and (nonBlank >= 2 or (nonBlank == 1 and ulen(cap.plain[1]) > 100))

  -- draw after the game's text for this packet has been processed
  tempTimer(0, function()
    if cap.kind == "help" then
      if replace then
        moveCursorEnd("main")
        if getCurrentLine("main") ~= "" then echo("main", "\n") end
        if nonBlank >= 2 then
          M.showHelp(cap.target, cap.decho)
          if M.cfg.mirror.help then
            for _, d in ipairs(cap.decho) do decho("main", d .. "\n") end
          else
            cecho("main", "<dim_grey>[sbo] help" .. (cap.target ~= "" and (" " .. cap.target) or "") ..
              " → help window<reset>\n")
          end
        else
          for _, d in ipairs(cap.decho) do decho("main", d .. "\n") end
        end
        if promptDecho then decho("main", promptDecho) end
        if heldPrompt then decho("main", heldPrompt) end
      end
      return
    end
    if replace then
      moveCursorEnd("main")
      if getCurrentLine("main") ~= "" then echo("main", "\n") end
      local windowOnly = worth and M.cfg.window and M.cfg.mirror.view == false
      local lines = worth and not windowOnly and M.format(cap.kind, cap.target, cap.plain, columns("main"), cap.decho)
      if windowOnly then
        -- in the Inspector only
      elseif lines then
        render("main", lines)
      else
        for _, d in ipairs(cap.decho) do decho("main", d .. "\n") end
      end
      if promptDecho then decho("main", promptDecho) end
      if heldPrompt then decho("main", heldPrompt) end
    end
    local entry
    if worth and M.cfg.window then
      M.pendingLinks = nil
      local lines = M.format(cap.kind, cap.target, cap.plain, M.viewCols(), cap.decho)
      if lines then entry = { lines = lines, links = M.pendingLinks or {} } end
      M.pendingLinks = nil
    end
    if cap.kind == "eq" then M.updateEqNames(cap.plain) end
    if cap.kind == "contents" then pcall(M.updateCarried, cap) end
    if cap.kind == "score" then M.updateMaxes(cap.plain); M.drawBar() end
    if cap.kind == "item" then M.afterItem(cap.plain, entry) end
    if entry then M.viewAdd(entry) end
  end)

  local nxt = table.remove(M.queue, 1)
  if nxt then M.start(nxt[1], nxt[2], nxt[3]) end
end

---------------------------------------------------------------------------
-- `sbo` command
---------------------------------------------------------------------------
-- (Mudlet reads <word> as a colour, so placeholders like <id> are shown as ‹id›)
local function say(msg)
  msg = tostring(msg):gsub("<", "‹"):gsub(">", "›")
  M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> " .. msg)
end
M.say = say

---------------------------------------------------------------------------
-- Map: follow your room by GMCP room number, and walk where you double-click
---------------------------------------------------------------------------
function M.mapRoomId()
  local info = type(gmcp) == "table" and gmcp.room and gmcp.room.info
  return info and tonumber(info.num)
end

function M.onRoom()
  local id = M.mapRoomId()
  if not id then return end
  M.mapRoom = id
  if roomExists(id) then M.centerOn(id) end
  pcall(M.drawMapHeader)
  -- walking: arrived where the next step should take us?
  local w = M.walk
  if w then
    if id == w.path[w.step] then
      w.step = w.step + 1
      if w.step > #w.dirs then
        M.walk = nil
        if w.thenRun then M.runStart(w.thenRun, w.target)
        elseif M.whereAfterWalk then local q = M.whereAfterWalk; M.whereAfterWalk = nil; tempTimer(0.5, function() pcall(M.whereGo, q) end)
        else M.notifyWalk("arrived") end
      else
        M.walkStep()
      end
    elseif id ~= w.from then
      M.walk = nil
      M.notifyWalk("stopped: ended up somewhere unexpected")
    end
  end
  pcall(M.shopOnArrive, id)
end

-- walk notes: a line in the game text (the prompt bar has no room to spare)
function M.notifyWalk(msg)
  say("walk " .. msg)
end

function M.walkStep()
  local w = M.walk
  if not w then return end
  w.from = M.mapRoom
  local mine, step = w, w.step
  M.sendOwn(w.dirs[w.step], false)
  -- no arrival within a few seconds (door, blocked, exhausted…): stop
  tempTimer(6, function()
    if M.walk == mine and mine.step == step then
      M.walk = nil
      M.notifyWalk("stopped: no progress (blocked or a closed door?)")
    end
  end)
end

-- Mudlet calls this when you double-click a room on the map; it fills in
-- speedWalkDir (directions) and speedWalkPath (the rooms they lead to)
function M.doSpeedWalk()
  if type(speedWalkDir) ~= "table" or #speedWalkDir == 0 then return end
  local dirs, path = {}, {}
  for i, d in ipairs(speedWalkDir) do dirs[i] = d; path[i] = tonumber(speedWalkPath[i]) end
  M.walk = { dirs = dirs, path = path, step = 1 }
  M.notifyWalk(string.format("%d step%s…", #dirs, #dirs == 1 and "" or "s"))
  M.walkStep()
end

---------------------------------------------------------------------------
-- Map panel: the map in an Oven window, with the current room on top and zoom/centre buttons
---------------------------------------------------------------------------
local mapHeaderStyle = "background-color: rgba(18,18,26,255); padding-left: 6px; qproperty-alignment: 'AlignVCenter | AlignLeft';"
local mapButtonStyle = [[
  QLabel { background-color: rgba(30,30,42,255); color: #c0c0c0; border-left: 1px solid #333;
           qproperty-alignment: 'AlignCenter'; }
  QLabel::hover { background-color: rgba(64,224,208,60); color: white; }]]

-- bump when the panel's contents change, so a panel built by an older version (in the same
-- Mudlet session) is rebuilt after an update instead of keeping its old layout
local MAP_PANEL_LAYOUT = 3

function M.createMapPanel()
  if M.mapPanel and M.mapPanelLayout == MAP_PANEL_LAYOUT then return end
  if M.mapPanel then
    pcall(function() M.mapPanel:hide() end)
    M.mapPanel, M.mapRoomLabel, M.mapSearchBox, M.mapWidget = nil, nil, nil, nil
  end
  M.mapPanelLayout = MAP_PANEL_LAYOUT
  M.mapPanel = Adjustable.Container:new({
    name = "ovenMapPanel",
    titleText = "Map",
    x = "-36%", y = "4%", width = "34%", height = "50%",
    adjLabelstyle = "background-color: rgba(20,20,28,235); border: 1px solid #555; border-radius: 4px;",
    titleTxtColor = "#e6c35c",
  })
  M.panelPlace("ovenMapPanel", M.mapPanel)
  local box = Geyser.VBox:new({ name = "ovenMapBox", x = 0, y = 0, width = "100%", height = "100%" }, M.mapPanel)
  local header = Geyser.HBox:new({ name = "ovenMapHeader", height = 24, v_policy = Geyser.Fixed }, box)
  M.mapRoomLabel = Geyser.Label:new({ name = "ovenMapRoom" }, header)
  M.mapRoomLabel:setStyleSheet(mapHeaderStyle)
  local function button(name, text, tip, fn)
    local b = Geyser.Label:new({ name = name, width = 28, h_policy = Geyser.Fixed }, header)
    b:setStyleSheet(mapButtonStyle)
    b:echo(text)
    pcall(function() b:setToolTip(tip) end)
    pcall(function() b:setCursor("PointingHand") end)
    b:setClickCallback(function() fn() end)
    return b
  end
  -- search box: type part of a room name, Enter
  local findLabel = Geyser.Label:new({ name = "ovenMapFindLabel", width = 36, h_policy = Geyser.Fixed }, header)
  findLabel:setStyleSheet("background-color: rgba(18,18,26,255); color: #808080; qproperty-alignment: 'AlignVCenter | AlignRight'; padding-right: 4px;")
  findLabel:echo("find")
  M.mapSearchBox = Geyser.CommandLine:new({ name = "ovenMapSearch", width = 150, h_policy = Geyser.Fixed }, header)
  pcall(function() M.mapSearchBox:setStyleSheet([[
    background-color: rgba(30,30,42,255); color: #c0c0c0; border: 1px solid #333;
    qproperty-placeholderText: "room name…";]]) end)
  M.mapSearchBox:setAction(function(text)
    M.mapSearchBox:clear()
    M.mapFind(text)
  end)
  button("ovenMapZoomOut", "−", "zoom out", function() M.mapZoom(1.25) end)
  button("ovenMapZoomIn", "+", "zoom in", function() M.mapZoom(0.8) end)
  button("ovenMapCentre", "◎", "centre on you", function() M.centerOn(M.mapRoom) end)
  M.mapWidget = Geyser.Mapper:new({ name = "ovenMapper", v_policy = Geyser.Dynamic }, box)
  if M.cfg.mapZoom then pcall(setMapZoom, M.cfg.mapZoom) end
end

function M.mapZoom(factor)
  local z = (M.cfg.mapZoom or 15) * factor
  z = math.max(3, math.min(60, z))
  M.cfg.mapZoom = z
  pcall(setMapZoom, z)
  M.saveSettings()
end

-- room name · area · #number in the header
function M.drawMapHeader()
  if not M.mapRoomLabel then return end
  local info = type(gmcp) == "table" and gmcp.room and gmcp.room.info or {}
  local id = tonumber(info.num) or M.mapRoom
  local name = info.name or (id and roomExists(id) and getRoomName(id)) or "?"
  local area = info.zone or ""
  local font = (pcall(getFont) and getFont()) or "monospace"
  local esc = function(x) return (tostring(x):gsub("&", "&amp;"):gsub("<", "&lt;")) end
  M.mapRoomLabel:echo(string.format(
    "<span style=\"font-family:'%s'; color:#ffffff;\">%s</span>"
    .. "<span style=\"font-family:'%s'; color:#808080;\">%s%s</span>",
    font, esc(name), font, area ~= "" and ("  ·  " .. esc(area)) or "", id and ("  ·  #" .. id) or ""))
end

---------------------------------------------------------------------------
-- Room card: click a room on the map panel and a card shows what's happened there -
-- kills, loot picked up, your deaths (and your level then). Mudlet itself decides which
-- room was clicked (its map selection), so it's always the right one.
---------------------------------------------------------------------------
function M.centerOn(id)
  if not id or not roomExists(id) then return end
  M.mapCenter = id
  centerview(id)
end

-- the room you're in, for the kill / loot / death records
function M.currentRoom()
  local info = type(gmcp) == "table" and gmcp.room and gmcp.room.info or {}
  return tonumber(info.num) or M.mapRoom
end

local function ago(t)
  if not t then return "" end
  local d = os.time() - t
  return d < 60 and "just now" or (M.shortDur(d) .. " ago")
end

-- the card's lines: { {colour, text}, ... } segments
function M.roomCardLines(id)
  local out = {}
  local function row(...) out[#out + 1] = { ... } end
  local name = getRoomName(id) or "?"
  local area = getRoomArea(id)
  local areaName = area and getRoomAreaName(area) or ""
  local title = { { C.item, name }, { C.dim, "  #" .. id } }
  local fl = M.roomFlagsOf(id)
  if fl and fl.tags and #fl.tags > 0 then
    title[#title + 1] = { C.dim, "  " }
    for _, t in ipairs(fl.tags) do title[#title + 1] = { C.flag, "[" .. t .. "]" } end
  end
  out[#out + 1] = title
  local exits = {}
  local okE, ex = pcall(getRoomExits, id)
  local short = { north = "n", south = "s", east = "e", west = "w", up = "u", down = "d",
                  northeast = "ne", northwest = "nw", southeast = "se", southwest = "sw", ["in"] = "in", out = "out" }
  if okE and type(ex) == "table" then
    for dir in pairs(ex) do exits[#exits + 1] = short[dir] or dir end
    table.sort(exits)
  end
  row({ C.dim, (areaName ~= "" and (areaName .. "  ·  ") or "") .. (#exits > 0 and ("exits " .. table.concat(exits, " ")) or "no exits mapped") })
  local okSh, shopRow = pcall(M.dbRow, "SELECT s.name, COUNT(i.item) AS n FROM shops s LEFT JOIN shop_items i ON i.room = s.room WHERE s.room = %s GROUP BY s.room", id)
  local okR, ref = pcall(M.dbRow, "SELECT said, level FROM shop_refusals WHERE room = %s", id)
  if not okSh then shopRow = nil end
  if not okR then ref = nil end
  if ref then
    -- won't sell to you: the shop's line in red, and why
    row({ C.minus, "$ " .. ((shopRow and shopRow.name) or "shop") .. " · won't sell to you" },
        { C.dim, "  '" .. tostring(ref.said) .. "'" .. (ref.level and ("  (level " .. ref.level .. ")") or "") })
  elseif shopRow then
    row({ C.slot, "$ " .. (shopRow.name or "a shop") }, { C.dim, "  " .. tostring(shopRow.n) .. " items (sbo map shops)" })
  end
  local okW, wrows = pcall(M.dbRows, "SELECT feature FROM where_rooms WHERE room = %s ORDER BY feature", id)
  if okW and #wrows > 0 then
    local f = {}
    for _, r in ipairs(wrows) do f[#f + 1] = r.feature end
    row({ C.slot, "◎ where is " .. table.concat(f, ", ") }, { C.dim, "  (sbo go " .. f[1] .. ")" })
  end
  local okS, sp = pcall(M.signAt, id)
  if okS and sp then
    local d = {}
    for n in pairs(sp.dests) do d[#d + 1] = n end
    table.sort(d)
    row({ C.slot, "⊕ signpost here" }, { C.dim, #d > 0 and ("  run " .. table.concat(d, " · ")) or "  (not read yet)" })
  end
  local marks = M.marksOf(id)
  if #marks > 0 then row({ C.slot, "★ " .. table.concat(marks, ", ") }, { C.dim, "  (sbo go " .. marks[1] .. ")" }) end
  local any = false
  local MAX = 8
  -- notable NPCs ([QUEST] [SHOP] [TRAINER] ...)
  local npcs = M.roomNpcsOf(id)
  if #npcs > 0 then
    any = true
    row(); row({ M.REC or C.title, "▸ Notable here" })
    for i, n in ipairs(npcs) do
      if i > MAX then row({ C.dim, string.format("  … and %d more", #npcs - MAX) }); break end
      local r = { { C.dim, "  " } }
      for _, t in ipairs(n.tags or {}) do r[#r + 1] = { t == "Traveling" and C.slot or C.flag, "[" .. t .. "] " } end
      r[#r + 1] = { C.text, n.text }
      if n.rooms then r[#r + 1] = { C.dim, "  · seen in " .. n.rooms .. " rooms" } end
      out[#out + 1] = r
    end
  end
  -- "enter ..." commands that work here
  local enters = M.roomEntersOf(id)
  if #enters > 0 then
    any = true
    row(); row({ M.REC or C.title, "▸ Ways in" })
    for _, e in ipairs(enters) do
      local dest = e.to and roomExists(e.to) and getRoomName(e.to) or nil
      row({ C.key, "  " .. e.cmd }, { C.dim, "  → " .. (dest and (dest .. "  #" .. e.to) or ("#" .. tostring(e.to))) })
    end
  end
  -- kills
  local kills = M.roomKillsOf(id)
  if #kills > 0 then
    any = true
    local total = 0
    for _, e in ipairs(kills) do total = total + e.count end
    row(); row({ M.REC or C.title, "▸ Killed here" }, { C.dim, "  " .. total })
    for i, e in ipairs(kills) do
      if i > MAX then row({ C.dim, string.format("  … and %d more", #kills - MAX) }); break end
      row({ C.num, string.format("  %3d× ", e.count) }, { C.text, e.name }, { C.dim, "  " .. ago(e.last) })
    end
  end
  -- loot
  local order = M.roomLootOf(id)
  if #order > 0 then
    any = true
    row(); row({ M.REC or C.title, "▸ Picked up here" })
    for i, f in ipairs(order) do
      if i > MAX then row({ C.dim, string.format("  … and %d more (sbo log loot #%d)", #order - MAX, id) }); break end
      local who = splitTags(f.who)
      table.sort(who)
      row({ C.num, string.format("  %3d× ", f.count) }, { C.item, f.item },
          { C.dim, "  " .. table.concat(who, ", ") .. " · " .. ago(f.last) })
    end
  end
  -- deaths
  local deaths = M.roomDeathsOf(id)
  if #deaths > 0 then
    any = true
    row(); row({ C.minus, "▸ You died here" }, { C.dim, "  " .. #deaths })
    for i = #deaths, math.max(1, #deaths - MAX + 1), -1 do
      local d = deaths[i]
      row({ C.text, "  " .. (d.level and ("at level " .. d.level) or "level unknown") .. (d.total and (" (total " .. d.total .. ")") or "") },
          { C.dim, "  " .. ago(d.t) })
    end
    row({ C.dim, "  what happened: sbo log deaths" })
  end
  if not any then row(); row({ C.dim, "nothing recorded here yet" }) end
  row(); row({ C.dim, "double-click the room to walk there · click this card to close" })
  return out
end

function M.showRoomCard(id, mx, my)
  local card = M.roomCard
  if not card then
    card = Geyser.Label:new({ name = "ovenRoomCard", x = 0, y = 0, width = 300, height = 100 })
    card:setStyleSheet("background-color: rgba(10,10,16,240); border: 1px solid #555; border-radius: 6px;")
    card:setClickCallback(function() M.hideRoomCard(true) end)
    M.roomCard = card
  end
  local lines = M.roomCardLines(id)
  local font = (pcall(getFont) and getFont()) or "monospace"
  local size = M.cfg.fontSize or 10
  local okF, cw, ch = pcall(calcFontSize, size, font)
  cw, ch = (okF and cw) or 8, (okF and ch) or 16
  local html, widest = {}, 0
  for _, segs in ipairs(lines) do
    local h, n = {}, 0
    for _, s in ipairs(segs) do h[#h + 1] = span(s[1], s[2]); n = n + ulen(s[2]) end
    html[#html + 1] = #h > 0 and table.concat(h) or "&nbsp;"
    widest = math.max(widest, n)
  end
  card:echo(string.format("<div style=\"font-family:'%s'; font-size:%dpt; white-space:pre; padding:6px 10px;\">%s</div>",
    font, size, table.concat(html, "<br>")))
  local w = math.min(640, widest * cw + 28)
  local h = math.ceil(#html * ch * 1.2) + 16
  card:resize(w, h)
  -- beside the click, kept inside the main window
  local W, H = getMainWindowSize()
  local x, y = (mx or 100) + 18, (my or 100) - 10
  if x + w > W then x = math.max(0, (mx or W) - w - 18) end
  if y + h > H then y = math.max(0, H - h) end
  card:move(x, y)
  card:show()
  pcall(function() card:raise() end)
  M.roomCardId = id
end

function M.hideRoomCard(clear)
  if M.roomCard then M.roomCard:hide() end
  M.roomCardId = nil
  if clear then pcall(clearMapSelection) end
end

-- the selected room on the map (one room, clicked), or nil
local function selectedRoom()
  local ok, sel = pcall(getMapSelection)
  if not ok or type(sel) ~= "table" then return end
  local rooms = sel.rooms or sel
  local n, only = 0, nil
  for _, r in pairs(rooms) do
    if tonumber(r) then n = n + 1; only = tonumber(r) end
  end
  if n == 1 then return only end
  if n == 0 and tonumber(sel.center) then return tonumber(sel.center) end
end

function M.mapSelectTick()
  if not (M.mapPanel and M.cfg.mapPanel) or M.cfg.mapCard == false then return M.hideRoomCard() end
  local id = selectedRoom()
  if id == M.mapSelected then return end
  M.mapSelected = id
  if id and roomExists(id) then
    local ok, mx, my = pcall(getMousePosition)
    M.showRoomCard(id, ok and mx, ok and my)
  else
    M.hideRoomCard()
  end
end

function M.startMapSelect()
  if M.mapSelTimer then killTimer(M.mapSelTimer) end
  M.mapSelected = selectedRoom()   -- whatever was selected before doesn't pop a card
  M.mapSelTimer = tempTimer(0.25, function() pcall(M.mapSelectTick) end, true)
end

function M.stopMapSelect()
  if M.mapSelTimer then killTimer(M.mapSelTimer); M.mapSelTimer = nil end
  M.hideRoomCard()
end

-- Notable NPCs: occupants of a room view carrying tags like [Quest] [Shop] [Trainer] [Boss], kept per
-- room. Only lines inside a room view are read (see the "room" block kind), so help pages, chat
-- and item descriptions can't be mistaken for them.
local NOT_TAGS = { CRIT = true }
-- tags that mark players, not NPCs ("[Clan 37] [Duelist] *Bing is here.")
local PLAYER_TAGS = { duelist = true, guide = true, building = true, hunting = true, a = true, outlaw = true, afk = true }

-- "*[Shop] A hunched-over senior citizen sits on a blanket, peddling his wares."
-- tags open the line (after an optional "*")
local function npcTags(l)
  local rest = l:gsub("^%s*%*?%s*", "")
  local tags = {}
  while true do
    local t, after = rest:match("^%[([^%]]+)%]%s*(.*)$")
    if not t then break end
    t = trim(t)
    local low = t:lower()
    if PLAYER_TAGS[low] or low:match("^clan%s*%d") then return end
    if not NOT_TAGS[t:upper()] and ulen(t) >= 3 and t:match("^%u[%a %-]*%a$") then tags[#tags + 1] = t end
    rest = after
  end
  local text = trim((rest:gsub("%s+", " "):gsub("^%*+%s*", "")))
  if text:match("^Item '") then return end
  if not text:match("^[%a%d\"']") then return end
  if #tags == 0 or text == "" or ulen(text) > 160 then return end
  -- speech isn't an occupant
  for _, v in ipairs({ " tells ", " says", " asks", " exclaims", " yells", " shouts", " whispers", " chats", " replies", "%a: " }) do
    if text:find(v) then return end
  end
  return tags, text
end
M.npcTags = npcTags

-- the prompt's tags describe the room ([SHOP] [SAFE] [Library]...), except [Mail], which is you
local NOT_ROOM_FLAGS = { mail = true }
function M.noteRoomFlags(id, l)
  if not id then return end
  -- GMCP's room.info has the room's real flags; the prompt's tags are the fallback
  local flags = M.gmcpRoomFlags(id)
  if not flags then
    flags = {}
    local before = l:match("^(.-)<") or l
    for t in before:gmatch("%[([^%]]+)%]") do
      if not NOT_ROOM_FLAGS[t:lower()] then flags[#flags + 1] = t end
    end
  end
  -- the prompt comes with every line of combat: only touch the database when the room changes
  local now_ = table.concat(flags, ",")
  if M.flagsSeen and M.flagsSeen.room == id and M.flagsSeen.tags == now_ then return end
  M.flagsSeen = { room = id, tags = now_ }
  local old = M.roomFlagsOf(id)
  local was = old and table.concat(old.tags or {}, ",") or nil
  if was == now_ then return end
  if #flags == 0 and not old then return end
  if #flags > 0 then
    M.dbx("INSERT OR REPLACE INTO room_flags (room, tags, last) VALUES (%s, %s, %s)", id, now_, os.time())
  else
    M.dbx("DELETE FROM room_flags WHERE room = %s", id)
  end
end

-- 0.16.7 took tags from anywhere on a line, so item lines ("Item '...' ... [Study][LTB]")
-- were saved as NPCs; drop those, and tidy leading "**" off names (run on the old data
-- before it's moved into the database)
function M.cleanRoomNpcs(roomNpcs)
  for _, book in pairs(roomNpcs or {}) do
    local drop, rename = {}, {}
    for key, n in pairs(book) do
      local t = n.text or ""
      if t:match("^Item '") or t:find("%[%u") then
        drop[#drop + 1] = key
      elseif t:match("^%*") then
        drop[#drop + 1] = key
        n.text = t:gsub("^%*+%s*", "")
        rename[#rename + 1] = n
      end
    end
    for _, key in ipairs(drop) do book[key] = nil end
    for _, n in ipairs(rename) do book[n.text:lower()] = n end
  end
end

function M.noteRoomLine(l)
  if not isPromptLine() then return end
  local id = M.currentRoom()
  pcall(M.noteRoomFlags, id, l)
  pcall(M.checkEnter, id)
end

-- "enter <something>": when it takes you to another room, remember it for the room you left,
-- and add it to the map as a special exit so walking can use it
function M.noteEnterCommand(cmd)
  local c = trim(cmd or "")
  if c:lower():match("^enter%s") or c:lower() == "enter" then
    M.pendingEnter = { cmd = c:lower(), from = M.currentRoom(), at = now() }
  end
end

function M.checkEnter(id)
  local p = M.pendingEnter
  if not p then return end
  if now() - p.at > 6 then M.pendingEnter = nil; return end
  if not id or not p.from or id == p.from then return end   -- not moved (yet)
  M.pendingEnter = nil
  M.dbx("INSERT OR REPLACE INTO room_enters (room, cmd, dest, last) VALUES (%s, %s, %s, %s)", p.from, p.cmd, id, os.time())
  if roomExists(p.from) and roomExists(id) then
    local ok, exits = pcall(getSpecialExitsSwap, p.from)
    if not (ok and type(exits) == "table" and exits[p.cmd]) then
      pcall(addSpecialExit, p.from, id, p.cmd)
    end
  end
end

-- what's known about a room, read from the database
function M.roomFlagsOf(id)
  local r = M.dbRow("SELECT tags, last FROM room_flags WHERE room = %s", id)
  return r and { tags = splitTags(r.tags), last = tonumber(r.last) }
end
function M.roomNpcsOf(id)
  local out = {}
  for _, r in ipairs(M.dbRows("SELECT key, text, tags, seen, last FROM room_npcs WHERE room = %s ORDER BY last DESC", id)) do
    local tags = splitTags(r.tags)
    local rooms
    for _, t in ipairs(tags) do
      if t:lower() == "shop" then
        local n = M.travelerRooms(r.key)
        if n >= 2 then rooms = n; tags[#tags + 1] = "Traveling" end
      end
    end
    out[#out + 1] = { text = r.text, tags = tags, seen = tonumber(r.seen), last = tonumber(r.last), rooms = rooms }
  end
  return out
end
function M.roomEntersOf(id)
  local out = {}
  for _, r in ipairs(M.dbRows("SELECT cmd, dest FROM room_enters WHERE room = %s ORDER BY cmd", id)) do
    out[#out + 1] = { cmd = r.cmd, to = tonumber(r.dest) }
  end
  return out
end
function M.roomKillsOf(id)
  local out = {}
  for _, r in ipairs(M.dbRows("SELECT MAX(name) AS name, SUM(n) AS count, MAX(t) AS last FROM kills WHERE room = %s GROUP BY key ORDER BY count DESC, last DESC", id)) do
    out[#out + 1] = { name = r.name, count = tonumber(r.count) or 0, last = tonumber(r.last) }
  end
  return out
end
function M.roomLootOf(id)
  local out = {}
  for _, r in ipairs(M.dbRows("SELECT MAX(item) AS item, SUM(n) AS count, MAX(t) AS last, group_concat(DISTINCT who) AS who FROM loot WHERE room = %s GROUP BY lower(item) ORDER BY last DESC", id)) do
    out[#out + 1] = { item = r.item, count = tonumber(r.count) or 1, last = tonumber(r.last), who = r.who or "?" }
  end
  return out
end
function M.roomDeathsOf(id)
  local out = {}
  for _, r in ipairs(M.dbRows("SELECT t, level, total, recap FROM deaths WHERE room = %s ORDER BY t", id)) do
    out[#out + 1] = { t = tonumber(r.t), level = tonumber(r.level), total = tonumber(r.total), recap = M.deser(r.recap) }
  end
  return out
end

-- the lines before a death, for the recap (prompts and blank lines left out)
function M.deathRecapLines()
  local out = {}
  for _, l in ipairs(M.recentLines or {}) do
    if trim(l) ~= "" and not l:match("^%[?.-<%d+hp") then out[#out + 1] = l end
  end
  return out
end

-- you died: "restore your soul to your body" happens where the body is, i.e. where you fell
function M.noteRoomDeath()
  local id = M.currentRoom()
  if not id then return end
  local c = M.cfg.char or {}
  local tg = M.live.target
  local killer = tg and tg.name and now() - (tg.at or 0) < 120 and tg.name or nil
  M.dbx("INSERT INTO deaths (t, room, level, total, recap, killer) VALUES (%s, %s, %s, %s, %s, %s)",
    os.time(), id, tonumber(c.level), tonumber(c.total), M.ser(M.deathRecapLines()), killer)
  if not M.rec then pcall(M.windowSave, "you died in room " .. tostring(id)) end
  -- the lines before it, so the game's own death message can be learned
  if M.cfg.samples and (M.deathCtxLogged or 0) < 10 then
    M.deathCtxLogged = (M.deathCtxLogged or 0) + 1
    local f = io.open(M.samplesFile, "a")
    if f then
      f:write("===== " .. os.date("%Y-%m-%d %H:%M:%S") .. " | kind=deathctx | cmd=\n")
      for _, x in ipairs(M.recentLines or {}) do f:write(x, "\n") end
      f:write("===== end\n\n")
      f:close()
    end
  end
end

-- Mudlet's own room-info overlay on the map (its "Short"/"Full" map info) repeats what the
-- panel's header shows, so it's switched off while the panel is up and restored afterwards
local function mapInfoOn()
  local ok, info = pcall(getMapInfo)
  local on = {}
  if ok and type(info) == "table" then
    for k, v in pairs(info) do
      if type(v) == "boolean" and v then on[#on + 1] = k
      elseif type(v) == "table" and v.enabled and (v.name or type(k) == "string") then on[#on + 1] = v.name or k end
    end
  end
  return on
end

function M.mapInfoOff()
  if M.cfg.mapInfoWas then return end   -- already done (and remembered what to restore)
  local on = mapInfoOn()
  for _, name in ipairs(on) do pcall(disableMapInfo, name) end
  M.cfg.mapInfoWas = on
  M.saveSettings()
end

function M.mapInfoRestore()
  local was = M.cfg.mapInfoWas
  if not was then return end
  for _, name in ipairs(was) do pcall(enableMapInfo, name) end
  M.cfg.mapInfoWas = nil
  M.saveSettings()
end

function M.showMapPanel(on)
  if on then
    M.createMapPanel()
    pcall(M.mapInfoOff)
    M.mapPanel:show()
    M.drawMapHeader()
    M.centerOn(M.mapRoom)
    M.startMapSelect()
    if M.raiseQuestHud then M.raiseQuestHud() end
  elseif M.mapPanel then
    M.mapPanel:hide()
    pcall(M.mapInfoRestore)
    M.stopMapSelect()
  end
end

-- map search: rooms whose name contains the text (rooms in your current area first)
function M.mapFind(q)
  q = trim(q or "")
  if q == "" then return say("usage: sbo map find <part of a room name>") end
  local ok, found = pcall(searchRoom, q)
  if not ok or type(found) ~= "table" then return say("map search isn't available (is a map loaded?)") end
  local here = M.mapRoom and roomExists(M.mapRoom) and getRoomArea(M.mapRoom)
  local rows = {}
  for key, name in pairs(found) do
    local id = tonumber(key)
    if id then
      local area = getRoomArea(id)
      rows[#rows + 1] = { id = id, name = name, area = area, areaName = area and getRoomAreaName(area) or "" }
    end
  end
  table.sort(rows, function(a, b)
    local ah, bh = a.area == here, b.area == here
    if ah ~= bh then return ah end
    if a.areaName ~= b.areaName then return a.areaName < b.areaName end
    return a.name < b.name
  end)
  local width = M.cfg.window and M.viewCols() or 80
  local out = { header("map", "", width, string.format("Map search: %s  (%d room%s)", q, #rows, #rows == 1 and "" or "s")) }
  local links = {}
  if #rows == 0 then out[#out + 1] = { { C.dim, "no rooms on the map match that" } } end
  for i, r in ipairs(rows) do
    if i > 25 then
      out[#out + 1] = { { C.dim, string.format("… and %d more - try a longer search", #rows - 25) } }
      break
    end
    local row = { { C.dim, pad("#" .. r.id, 8) }, { C.item, r.name } }
    if r.areaName ~= "" then row[#row + 1] = { r.area == here and C.slot or C.dim, "  · " .. r.areaName } end
    out[#out + 1] = row
    local id, nm = r.id, r.name
    links[#links + 1] = { "show #" .. id .. " " .. nm, function() M.mapShow(id) end }
    links[#links + 1] = { "walk to #" .. id .. " " .. nm, function() M.mapWalkTo(id) end }
  end
  M.viewOut(out, links)
  if rows[1] and #rows == 1 then M.mapShow(rows[1].id) end
end

-- centre the map on a room and highlight it (the previous highlight is cleared)
function M.mapShow(id)
  if not roomExists(id) then return say("room #" .. id .. " isn't on the map") end
  if M.mapHighlight then pcall(unHighlightRoom, M.mapHighlight) end
  pcall(highlightRoom, id, 64, 224, 208, 64, 224, 208, 1.5, 200, 60)
  M.mapHighlight = id
  if M.mapPanel and M.cfg.mapPanel then M.showMapPanel(true) end   -- (this centres on you...)
  M.centerOn(id)                                                    -- ...so centre on the room after
end

-- walk to a room the way a double-click on the map does
function M.mapWalkTo(id, onFoot)
  id = tonumber(id)
  if not id or not roomExists(id) then return say("room #" .. tostring(id) .. " isn't on the map") end
  if not M.mapRoom then return say("Oven doesn't know where you are yet - move one room first") end
  M.mapShow(id)
  if not getPath(M.mapRoom, id) then return say("no route on the map from here to #" .. id) end
  local dirs, path = {}, {}
  for i, d in ipairs(speedWalkDir) do dirs[i] = d; path[i] = tonumber(speedWalkPath[i]) end
  if #dirs == 0 then return say("you're already there") end
  if not onFoot then
    local okP, plan = pcall(M.runPlan, M.mapRoom, id, dirs, path)
    if okP and plan then return M.runVia(plan, id, dirs) end
  end
  M.walk = { dirs = dirs, path = path, step = 1 }
  M.notifyWalk(string.format("%d step%s…", #dirs, #dirs == 1 and "" or "s"))
  M.walkStep()
end

---------------------------------------------------------------------------
-- Signpost runs: "run <name>" in the wilds runs you along the roads, signpost to signpost, to a town
-- (run rune, run towerofart). Oven learns the names from signposts you look at and where each run
-- ends from the runs you make; walks (sbo go, double-clicking the map) then use a run when it saves
-- a long walk: walk to the wilds, run, walk the rest.
---------------------------------------------------------------------------
M.RUN_COST = 25    -- a run counted as this many steps (quick, but it costs stamina and can be cut short)
M.RUN_SAVES = 30   -- and only used when it saves at least this many more

-- signposts, by room
local function destsStr(d)
  local t = {}
  for n, dir in pairs(d) do t[#t + 1] = n .. "=" .. dir end
  table.sort(t)
  return table.concat(t, ";")
end
local function destsOf(str)
  local d = {}
  for n, dir in tostring(str or ""):gmatch("([^;=]+)=([^;]+)") do d[n] = dir end
  return d
end
M.destsOf = destsOf

function M.signAt(room)
  local r = room and M.dbRow("SELECT room, sign, dests, exact, last FROM signposts WHERE room = %s", room)
  if not r then return nil end
  return { room = tonumber(r.room), sign = r.sign, dests = destsOf(r.dests), looked = (r.dests or "") ~= "",
           exact = tonumber(r.exact) == 1, last = tonumber(r.last) }
end

-- one you've looked at (or seen standing here): exact, with its destinations
function M.signSave(room, sign, dests)
  if not room then return end
  local old = M.signAt(room)
  M.dbx("INSERT OR REPLACE INTO signposts (room, sign, dests, exact, last) VALUES (%s, %s, %s, 1, %s)",
    room, sign or (old and old.sign), dests and destsStr(dests) or (old and destsStr(old.dests)) or "", os.time())
end

-- before 0.49 "You take note of the directions on a signpost…" (said while running) was logged as loot
function M.signMigrate()
  M.dbx("DELETE FROM loot WHERE item LIKE 'note of the directions on %%'")
  M.dbx("DELETE FROM signposts WHERE exact = 0")   -- 0.49.0 kept those as "near a signpost": no use for running
end

function M.runData()
  M.cfg.runs = M.cfg.runs or {}
  local r = M.cfg.runs
  r.names, r.ends, r.wilds = r.names or {}, r.ends or {}, nil
  return r
end

-- "Item 'a weatherbeaten signpost outside New Rigel's south gate' is type roadsign" then "* towerofart is south."
function M.noteSignpost(sign)
  pcall(M.signSave, M.mapRoom, sign.item, sign.dests)
  local r, new = M.runData(), 0
  for n in pairs(sign.dests) do
    if not r.names[n] then r.names[n] = { first = sign.item }; new = new + 1 end
  end
  if new > 0 then
    M.saveSettings()
    say(string.format("%d new signpost run%s (run <name> in the wilds) - sbo map signposts lists them", new, new == 1 and "" or "s"))
  end
end

function M.runNames()
  local out = {}
  for n in pairs(M.runData().names) do out[n] = true end
  for _, row in ipairs(M.dbRows("SELECT dests FROM signposts WHERE dests != ''")) do
    for n in pairs(destsOf(row.dests)) do out[n] = true end
  end
  return out
end

-- a signpost in the room you're in that Oven hasn't read: look at it quietly, once you're idle
M.signTried = M.signTried or {}
function M.signAutoLook(room, promptLine)
  if not M.cfg.signLook or not room or M.signTried[room] or room ~= M.mapRoom then return end
  local known = M.signAt(room)
  if known and known.looked then return end
  if M.cap or M.learning or M.learnQueue or M.quietNext or M.walk or M.running or M.fighting() or not M.inGame(promptLine) then return end
  M.signTried[room] = true
  M.quietly("look signpost", "item", function() end)
end

-- a run you typed (or an alias for one)
function M.noteRunCommand(cmd)
  local name = trim(cmd or ""):lower():match("^run%s+(%S+)$")
  if not name then return end
  local R = M.running
  if R and R.ours and R.name == name and not R.sentSeen then R.sentSeen = true; return end
  M.running = { name = name, at = now(), from = M.mapRoom }
end

function M.runStart(name, target)
  if M.running and M.running.timer then pcall(killTimer, M.running.timer) end
  M.running = { name = name, target = target, at = now(), from = M.mapRoom, ours = true }
  local mine = M.running
  M.sendOwn("run " .. name, false)
  mine.timer = tempTimer(6, function()
    if M.running == mine and not mine.started then M.runFailed("the game didn't start the run") end
  end)
end

function M.runFailed(why)
  local R = M.running
  M.running = nil
  if not R then return end
  if R.timer then pcall(killTimer, R.timer) end
  if R.target then
    M.notifyWalk("run " .. R.name .. ": " .. why .. " - walking instead")
    M.mapWalkTo(R.target, true)
  end
end

function M.runStopped(atSign)
  local R = M.running
  M.running = nil
  if not R then return end
  if R.timer then pcall(killTimer, R.timer) end
  local here = M.mapRoom
  -- a run ends at a signpost; anywhere else it was cut short
  if atSign and R.started and here then
    local r = M.runData()
    local old = r.ends[R.name]
    r.names[R.name] = r.names[R.name] or {}
    if old ~= here then
      r.ends[R.name] = here
      M.saveSettings()
      if not old then
        say(string.format("run %s ends at %s #%d - Oven's walks will use it", R.name,
          (roomExists(here) and getRoomName(here)) or "this room", here))
      end
    end
  end
  if not R.target then return end
  if here == R.target then return M.notifyWalk("arrived") end
  if atSign then return M.mapWalkTo(R.target, true) end   -- the rest on foot
  M.notifyWalk("stopped: the run was cut short" .. (here and (" at #" .. here) or "") .. " - sbo go again to go on")
end

M.addBlockReader("signpost_runs", "*", function(b)
  local sign, atSign
  for _, l in ipairs(b.lines) do
    local t = trim(l)
    local item = t:match("^Item '(.-)' is type roadsign")
    if item then sign = { item = item, dests = {} } end
    if sign then
      local n, d = t:match("^%* (%l+) is (%a+)%.$")
      if n then sign.dests[n] = d end
    end
    if t:match("signpost is firmly planted here%.$") then atSign = true end
    local R = M.running
    if R then
      if t == "You start running." then R.started = true end
      if t == "That only works in the wilds!" then M.runFailed("only works in the wilds") end
      if t == "You stop running." then M.runStopped(atSign) end
    end
  end
  if sign and next(sign.dests) then M.noteSignpost(sign) end
  if atSign and b.prompt and M.mapRoom then
    local room, p = M.mapRoom, b.lines[#b.lines]
    tempTimer(0, function() pcall(M.signAutoLook, room, p) end)
  end
end)

-- the run named after the area a room is in: "Towne of Rune" -> rune, "Tower of Art" -> towerofart
function M.runForArea(id)
  local a = id and roomExists(id) and getRoomArea(id)
  local an = a and getRoomAreaName(a)
  if not an or an == "" then return nil end
  local words = {}
  for w in an:lower():gmatch("%a+") do words[#words + 1] = w end
  local full = table.concat(words)
  -- "Towne of Rune", "City of X", "The X": the name without the lead-in
  local short = full
  local lead = { "towneof", "townof", "cityof", "villageof", "the" }
  for _, l in ipairs(lead) do if short:sub(1, #l) == l and #short > #l + 2 then short = short:sub(#l + 1); break end end
  local names = M.runNames()
  if names[full] then return full end
  if names[short] then return short end
end

-- the quickest way from here to target using one run, when it beats walking by enough
function M.runPlan(here, target, dirs, path)
  local r = M.runData()
  local direct = #dirs
  local town = target and M.runForArea(target)
  local afterCache = {}
  local function after(name)
    if afterCache[name] == nil then
      local e = r.ends[name]
      local n = false
      if e and target then
        if e == target then n = 0 elseif roomExists(e) and getPath(e, target) then n = #speedWalkDir end
      end
      afterCache[name] = n
    end
    return afterCache[name]
  end
  local best
  -- a run starts at a signpost: walk to one you've read, run, then walk the rest
  for _, sp in ipairs(M.signposts()) do
    local k
    if sp.room == here then k = 0 elseif roomExists(sp.room) and getPath(here, sp.room) then k = #speedWalkDir end
    if k then
      for name in pairs(sp.dests) do
        local n, cost = after(name), nil
        if n then cost = k + M.RUN_COST + n
        elseif name == town and not r.ends[name] then cost = k + M.RUN_COST end   -- end not known yet: walk on from wherever it stops
        if cost and (not target or cost + M.RUN_SAVES <= direct) and (not best or cost < best.cost) then
          best = { name = name, cost = cost, k = k, start = sp.room, after = n or 0, unknown = not n }
        end
      end
    end
  end
  return best
end

-- signposts you've read: { room, dests }
function M.signposts()
  local out = {}
  for _, row in ipairs(M.dbRows("SELECT room, dests FROM signposts WHERE exact = 1 AND dests != ''")) do
    out[#out + 1] = { room = tonumber(row.room), dests = destsOf(row.dests) }
  end
  return out
end

function M.runVia(plan, target, dirs)
  local parts = {}
  if plan.k > 0 then parts[#parts + 1] = string.format("%d step%s to the signpost", plan.k, plan.k == 1 and "" or "s") end
  parts[#parts + 1] = "run " .. plan.name
  if target then
    if plan.unknown then parts[#parts + 1] = "walk the rest"
    elseif plan.after > 0 then parts[#parts + 1] = string.format("%d step%s", plan.after, plan.after == 1 and "" or "s") end
  end
  M.notifyWalk(table.concat(parts, ", then ") .. (dirs and string.format("  (instead of %d steps)", #dirs) or ""))
  if plan.k == 0 then return M.runStart(plan.name, target) end
  if not getPath(M.mapRoom, plan.start) then return say("no route on the map to the signpost #" .. plan.start) end
  local d, p = {}, {}
  for i2, x in ipairs(speedWalkDir) do d[i2] = x; p[i2] = tonumber(speedWalkPath[i2]) end
  M.walk = { dirs = d, path = p, step = 1, thenRun = plan.name, target = target }
  M.walkStep()
end

-- sbo go <name> with no known end: to the nearest signpost that lists it, and run
function M.runFrom(name)
  local here = M.mapRoom
  local best
  for _, sp in ipairs(M.signposts()) do
    if sp.dests[name] then
      local k
      if sp.room == here then k = 0 elseif here and roomExists(sp.room) and getPath(here, sp.room) then k = #speedWalkDir end
      if k and (not best or k < best.k) then best = { name = name, k = k, start = sp.room, cost = k, after = 0 } end
    end
  end
  if not best then return say("no signpost Oven has read lists '" .. name .. "' - stand at one and Oven reads it") end
  M.runVia(best, nil, nil)
end

-- sbo map signposts
function M.runList()
  local r = M.runData()
  local names = {}
  for n in pairs(M.runNames()) do names[#names + 1] = n end
  table.sort(names)
  local nPosts = #M.signposts()
  local posts = string.format("%d signpost%s read", nPosts, nPosts == 1 and "" or "s")
  if #names == 0 then return say("no signpost run names yet (" .. posts .. ") - stand at a weatherbeaten signpost in the wilds and Oven reads it") end
  local width = M.cfg.window and M.viewCols() or 80
  local out = { header("map", "", width, string.format("Signpost runs  (%d)", #names)) }
  out[#out + 1] = { { C.dim, "runs start at a signpost; walks go to one, run, and learn where each run ends  ·  " .. posts } }
  out[#out + 1] = {}
  local links, w = {}, 0
  for _, n in ipairs(names) do w = math.max(w, ulen(n)) end
  for _, n in ipairs(names) do
    local e = r.ends[n]
    if e then
      out[#out + 1] = { { C.item, "  " .. pad(n, w + 2) }, { C.plus, "ends at " }, { C.key, (roomExists(e) and getRoomName(e)) or "?" }, { C.dim, "  #" .. e } }
      links[#links + 1] = { "run " .. n, function() M.mapRun(n) end }
    else
      out[#out + 1] = { { C.item, "  " .. pad(n, w + 2) }, { C.dim, "end not known yet - learned the first time it's run" } }
      links[#links + 1] = { "run " .. n, function() M.mapRun(n) end }
    end
  end
  M.viewOut(out, links)
end

-- sbo go <what>: run to the nearest room that has it - an NPC tag or name ([Trainer], [Shop],
-- "cleric"), a room tag ([Library]), or failing those a room name; or a room number
-- Bookmarks: name the room you're in, then `sbo go <name>` takes you back
function M.markRoom(name)
  name = trim(name or ""):lower()
  local id = M.currentRoom()
  if not id then return say("Oven doesn't know which room you're in yet - move one room first") end
  M.dbx("INSERT OR REPLACE INTO marks (name, room, t) VALUES (%s, %s, %s)", name, id, os.time())
  pcall(M.mapLearned)
  say(string.format("bookmarked %s #%d as '%s' - sbo go %s", (roomExists(id) and getRoomName(id)) or "this room", id, name, name))
end

function M.unmarkRoom(name)
  name = trim(name or ""):lower()
  if not M.dbRow("SELECT room FROM marks WHERE name = %s", name) then return say("no bookmark called '" .. name .. "'") end
  M.dbx("DELETE FROM marks WHERE name = %s", name)
  say("bookmark '" .. name .. "' removed")
end

function M.marksOf(id)
  local out = {}
  for _, r in ipairs(M.dbRows("SELECT name FROM marks WHERE room = %s ORDER BY name", id)) do out[#out + 1] = r.name end
  return out
end

function M.listMarks()
  local rows = M.dbRows("SELECT name, room FROM marks ORDER BY name")
  if #rows == 0 then return say("no bookmarks yet - stand somewhere and type sbo map mark <name>") end
  local width = M.cfg.window and M.viewCols() or 80
  local out = { header("map", "", width, string.format("Bookmarks  (%d)", #rows)) }
  local links = {}
  local w = 0
  for _, r in ipairs(rows) do w = math.max(w, ulen(r.name)) end
  for _, r in ipairs(rows) do
    local id = tonumber(r.room)
    local nm = (id and roomExists(id) and getRoomName(id)) or "?"
    out[#out + 1] = { { C.slot, pad(r.name, w + 2) }, { C.item, nm }, { C.dim, "  #" .. tostring(id) } }
    links[#links + 1] = { "run to " .. r.name, function() M.mapRun(r.name) end }
  end
  out[#out + 1] = {}
  out[#out + 1] = { { C.dim, "sbo go <name> to go there · sbo map unmark <name> to remove one" } }
  M.viewOut(out, links)
end

-- Deaths: where, at what level, and the lines that led up to it
function M.deathLines(width)
  local rows = M.dbRows("SELECT t, room, level, total, recap, killer FROM deaths ORDER BY t DESC LIMIT 10")
  local total = M.dbRow("SELECT COUNT(*) AS c FROM deaths")
  local out = { header("deaths", "", width, string.format("Deaths  (%s in all)", tostring(total and total.c or 0))) }
  local links = {}
  if #rows == 0 then out[#out + 1] = { { C.dim, "no deaths recorded - long may it last" } } end
  for _, r in ipairs(rows) do
    local id = tonumber(r.room)
    local nm = (id and roomExists(id) and getRoomName(id)) or "?"
    out[#out + 1] = {}
    out[#out + 1] = { { C.minus, "▸ " .. os.date("%Y-%m-%d %H:%M", tonumber(r.t)) }, { C.item, "  " .. nm }, { C.dim, "  #" .. tostring(id) },
                      { C.text, r.level and ("  · level " .. r.level) or "" },
                      { C.dim, r.killer and ("  · fighting " .. r.killer) or "" } }
    local recap = M.deser(r.recap)
    if recap and #recap > 0 then
      for i = math.max(1, #recap - 14), #recap do out[#out + 1] = { { C.dim, "    " .. recap[i] } } end
    else
      out[#out + 1] = { { C.dim, "    (no recap: recorded before 0.19)" } }
    end
    if id then links[#links + 1] = { "map: " .. nm .. " #" .. id, function() M.mapShow(id) end } end
  end
  return out, links
end

function M.runTargets(q)
  q = trim(q or ""):lower()
  local single = q:gsub("s$", "")          -- "trainers" finds [Trainer]
  local found, order = {}, {}
  local function add(id, why, rank)
    id = tonumber(id)
    if not id or not roomExists(id) then return end
    local f = found[id]
    if not f then f = { id = id, why = why, rank = rank }; found[id] = f; order[#order + 1] = f
    elseif rank < f.rank then f.why, f.rank = why, rank end
  end
  for _, r in ipairs(M.dbRows("SELECT name, room FROM marks WHERE name = %s OR instr(name, %s) = 1", q, q)) do
    add(r.room, "bookmark '" .. r.name .. "'", r.name == q and 0 or 0.5)
  end
  -- the game's "where is" features Oven has found ("food" in Towne of Rune)
  for _, r in ipairs(M.whereRooms(q)) do
    add(r.room, "where is " .. r.feature .. " (" .. tostring(r.area) .. ")", r.feature == q and 0.7 or 0.8)
  end
  local npcRooms = {}
  for _, r in ipairs(M.dbRows("SELECT room, text, tags FROM room_npcs WHERE instr(lower(tags), %s) > 0 OR instr(lower(text), %s) > 0", single, q)) do
    npcRooms[r.room] = npcRooms[r.room] or {}
    table.insert(npcRooms[r.room], { text = r.text, tags = splitTags(r.tags) })
  end
  for id, book in pairs(npcRooms) do
    for _, n in pairs(book) do
      local tagHit
      for _, t in ipairs(n.tags or {}) do
        local tl = t:lower()
        if tl == q or tl == single or tl:sub(1, #q) == q then tagHit = true end
      end
      local label = ""
      for _, t in ipairs(n.tags or {}) do label = label .. "[" .. t .. "] " end
      label = label .. (n.text or "")
      if tagHit then add(id, label, 1)
      elseif (n.text or ""):lower():find(q, 1, true) then add(id, label, 2) end
    end
  end
  for _, r in ipairs(M.dbRows("SELECT room, tags FROM room_flags WHERE instr(lower(tags), %s) > 0", single)) do
    local id = r.room
    for _, t in ipairs(splitTags(r.tags)) do
      local tl = t:lower()
      if tl == q or tl == single then add(id, "[" .. t .. "]", 3) end
    end
  end
  local fromNotes = #order > 0
  if not fromNotes then
    local ok, rooms = pcall(searchRoom, q)
    if ok and type(rooms) == "table" then
      for key, name in pairs(rooms) do add(key, name, 4) end
    end
  end
  return order, fromNotes
end

function M.mapRun(arg)
  arg = trim(arg or "")
  local all = arg:match("^all%s+(.+)$")
  local q = all or arg
  if q == "" then return say("usage: sbo go <trainer|shop|quest|… or part of a name or room # >  (sbo map find <what> lists them)") end
  if q == "stop" then return M.command("map stop") end
  if tonumber(q) then return M.mapWalkTo(tonumber(q)) end
  local sign = not all and M.runNames()[q:lower()] and q:lower()
  if sign then
    local e = M.runData().ends[sign]
    if e and M.cfg.map and M.mapRoom and roomExists(e) then return M.mapWalkTo(e) end
    return M.runFrom(sign)
  end
  if not M.cfg.map then return say("map following is off - sbo config map on first") end
  local here = M.mapRoom or M.currentRoom()
  if not here or not roomExists(here) then return say("Oven doesn't know where you are on the map yet - move one room first") end
  local targets, fromNotes = M.runTargets(q)
  if #targets == 0 or (not fromNotes and #M.whereAreas(q) > 0) then
    -- a feature the game knows by name (where is food): ask it
    if not all and (#M.whereAreas(q) > 0 or #targets == 0) and q:match("^[%w%-]+$") and M.whereGo(q) then return end
  end
  if #targets == 0 then return say("nothing called '" .. q .. "' that Oven has seen, and no room on the map by that name") end
  -- walking distance to each (the nearest 60 candidates are plenty)
  local reach = {}
  for i, t in ipairs(targets) do
    if i > 60 then break end
    if t.id == here then t.steps = 0; reach[#reach + 1] = t
    elseif getPath(here, t.id) then t.steps = #speedWalkDir; reach[#reach + 1] = t end
  end
  if #reach == 0 then
    -- say what was found, so it's clear whether it's the place you meant
    local names = {}
    for i, t in ipairs(targets) do
      if i > 3 then names[#names + 1] = "…"; break end
      local area = getRoomArea(t.id)
      area = area and getRoomAreaName(area) or ""
      names[#names + 1] = (getRoomName(t.id) or "?") .. " #" .. t.id .. (area ~= "" and (" (" .. area .. ")") or "")
    end
    return say(string.format("no route on the map from here (#%d) to %s%s", here, table.concat(names, ", "),
      fromNotes and "" or string.format(" - a room name match: Oven hasn't seen an NPC tagged or named '%s' yet", q)))
  end
  table.sort(reach, function(a, b) if a.rank ~= b.rank then return a.rank < b.rank end return a.steps < b.steps end)
  -- best kind of match first, then the nearest of that kind
  -- (not the room you're standing in: running to "trainer" at a trainer goes to the next one)
  local best
  for _, t in ipairs(reach) do
    if t.steps > 0 and (not best or t.rank < best.rank or (t.rank == best.rank and t.steps < best.steps)) then best = t end
  end
  if all then
    table.sort(reach, function(a, b) return a.steps < b.steps end)
    local width = M.cfg.window and M.viewCols() or 80
    local out = { header("map", "", width, string.format("Run: %s  (%d reachable)", q, #reach)) }
    local links = {}
    for i, t in ipairs(reach) do
      if i > 25 then out[#out + 1] = { { C.dim, "… and " .. (#reach - 25) .. " more" } }; break end
      out[#out + 1] = { { C.num, string.format("%4d steps  ", t.steps) }, { C.item, getRoomName(t.id) or "?" }, { C.dim, "  #" .. t.id } }
      if t.why ~= getRoomName(t.id) then out[#out + 1] = { { C.dim, "            " .. t.why } } end
      local id = t.id
      links[#links + 1] = { "run to #" .. id .. " " .. (getRoomName(id) or ""), function() M.mapWalkTo(id) end }
    end
    M.viewOut(out, links)
    return
  end
  if not best then return say("you're already at the only " .. q .. " Oven knows of") end
  local others = 0
  for _, t in ipairs(reach) do if t ~= best and t.steps > 0 then others = others + 1 end end
  say(string.format("running to %s · %s #%d · %d step%s%s", best.why, getRoomName(best.id) or "?", best.id,
    best.steps, best.steps == 1 and "" or "s",
    others > 0 and string.format("  (%d other%s: sbo map find %s)", others, others == 1 and "" or "s", q) or ""))
  M.mapWalkTo(best.id)
end

function M.mapStart()
  if M.mapHandler then killAnonymousEventHandler(M.mapHandler) end
  M.mapHandler = registerAnonymousEventHandler("gmcp.room.info", function() M.onRoom() end)
  doSpeedWalk = function() M.doSpeedWalk() end   -- the global Mudlet's map calls
  M.onRoom()
end

function M.mapStop()
  if M.mapHandler then killAnonymousEventHandler(M.mapHandler); M.mapHandler = nil end
  if doSpeedWalk and M.cfg.map == false then doSpeedWalk = nil end
  M.walk = nil
end

---------------------------------------------------------------------------
-- Kill log: "<creature> has been slain!", with the exp that follows it
---------------------------------------------------------------------------
local function killBook(book, key, name)
  local e = book[key]
  if not e then e = { name = name, count = 0, exp = 0 }; book[key] = e end
  return e
end

function M.recordKill(name)
  name = trim(name)
  local key = name:lower()
  M.sess.killBook = M.sess.killBook or {}
  local t = os.time()
  local e = killBook(M.sess.killBook, key, name)
  e.count = e.count + 1
  e.last = t
  M.sess.killsLive = (M.sess.killsLive or 0) + 1
  local tg = M.targetFor(name) or {}
  M.dbx("INSERT INTO kills (t, key, name, room, n, exp, vnum, race) VALUES (%s, %s, %s, %s, 1, 0, %s, %s)",
    t, key, name, M.currentRoom(), tg.vnum, tg.race)
  M.lastKill = { key = key, at = now(), id = M.dbLastId() }
  pcall(M.drawBar)
end

-- exp gained within a few seconds of a kill is credited to it
function M.creditKillExp(n)
  local k = M.lastKill
  if not k or now() - k.at > 5 then return end
  local e = (M.sess.killBook or {})[k.key]
  if e then e.exp = (e.exp or 0) + n end
  if k.id then M.dbx("UPDATE kills SET exp = exp + %s WHERE id = %s", n, k.id) end
  M.lastKill = nil
end

local function killTable(out, title, book, width, limit)
  local rows = {}
  for _, e in pairs(book or {}) do rows[#rows + 1] = e end
  table.sort(rows, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.name:lower() < b.name:lower()
  end)
  local total = 0
  for _, e in ipairs(rows) do total = total + e.count end
  subhead(out, string.format("%s  (%d kill%s, %d kind%s)", title, total, total == 1 and "" or "s", #rows, #rows == 1 and "" or "s"))
  if #rows == 0 then out[#out + 1] = { { C.dim, "  nothing yet" } }; return end
  local nameW = ulen("Creature")
  for i, e in ipairs(rows) do if i <= (limit or #rows) then nameW = math.max(nameW, math.min(40, ulen(e.name))) end end
  out[#out + 1] = { { C.key, "  " .. pad("Creature", nameW + 2) .. string.format("%6s %10s   %s", "Kills", "Exp", "Last") } }
  for i, e in ipairs(rows) do
    if limit and i > limit then
      out[#out + 1] = { { C.dim, string.format("  … and %d more (sbo log kills)", #rows - limit) } }
      break
    end
    local nm = ulen(e.name) > 40 and (M.usub(e.name, 1, 39) .. "…") or e.name
    local ago = e.last and M.shortDur(os.time() - e.last) .. " ago" or ""
    out[#out + 1] = { { C.item, "  " .. pad(nm, nameW + 2) }, { C.num, string.format("%6d ", e.count) },
                      { (e.exp or 0) > 0 and C.plus or C.dim, string.format("%10s", (e.exp or 0) > 0 and M.commaNum(e.exp) or "-") },
                      { C.dim, "   " .. ago } }
  end
end

function M.killLines(width, all)
  local out = { header("kills", "", width, "Kills") }
  killTable(out, "This session", M.sess.killBook, width, all and nil or 25)
  local book = {}
  for _, r in ipairs(M.dbRows("SELECT key, MAX(name) AS name, SUM(n) AS count, SUM(exp) AS exp, MAX(t) AS last FROM kills GROUP BY key")) do
    book[r.key] = { name = r.name, count = tonumber(r.count) or 0, exp = tonumber(r.exp) or 0, last = tonumber(r.last) }
  end
  killTable(out, "All time", book, width, all and nil or 25)
  return out
end

---------------------------------------------------------------------------
-- Loot log: what you (or anyone with you) pick up, and the exact room it was in
---------------------------------------------------------------------------
-- "You get ..." lines that aren't items
local NOT_LOOT = { "^the feeling", "^a feeling", "^the sense", "^a sense", "^the impression", "^the idea",
                   "^nothing", "^hungry", "^thirsty", "^tired", "^up", "^dressed", "^undressed",
                   "^better", "^worse", "^lost", "^a chance", "^the chance", "^ready", "^experience",
                   "^note of " }   -- "You take note of the directions on a weatherbeaten signpost…"

function M.parseLoot(l)
  l = trim(l)
  -- "A bottle of pesto emits a bright flare of white light as you take it and it binds with you."
  if l:find(" as you take it", 1, true) then
    for _, v in ipairs({ "emits", "glows", "flares", "flashes", "shimmers", "sparkles", "hums", "pulses", "vibrates",
                         "crackles", "tingles", "binds", "bonds", "shudders", "warms", "chills", "flickers", "glimmers" }) do
      local took = l:match("^(%u.-) " .. v .. " ")
      if took and ulen(took) <= 60 then
        return { who = "you", item = took:sub(1, 1):lower() .. took:sub(2), count = 1 }
      end
    end
  end
  local who, rest = l:match("^(You) get (.+)$")
  if not who then who, rest = l:match("^(You) take (.+)$") end
  if not who then who, rest = l:match("^(You) pick up (.+)$") end
  if not who then who, rest = l:match("^(%u[%a'%-]+) gets (.+)$") end
  if not who then who, rest = l:match("^(%u[%a'%-]+) takes (.+)$") end
  if not who then who, rest = l:match("^(%u[%a'%-]+) picks up (.+)$") end
  if not rest then return end
  -- a stack count can come before or after the full stop: "a potion. [x3]", "a potion (x3)."
  local count = 1
  local function takeCount()
    local n = rest:match("%s*%[x?(%d+)%]$") or rest:match("%s*%(x?(%d+)%)$")
    if n then count = tonumber(n); rest = rest:gsub("%s*[%[%(]x?%d+[%]%)]$", "") end
  end
  takeCount()
  if not rest:match("[%.!]$") then return end
  rest = rest:gsub("[%.!]+$", "")
  takeCount()
  local item, from = rest:match("^(.+) from (.+)$")
  item = trim(item or rest)
  local low = item:lower()
  for _, p in ipairs(NOT_LOOT) do if low:match(p) then return end end
  if ulen(item) > 90 or item == "" then return end
  return { who = who == "You" and "you" or who, item = item, from = from and trim(from) or nil, count = count }
end

local function lootRoom()
  local info = type(gmcp) == "table" and gmcp.room and gmcp.room.info or {}
  local id = tonumber(info.num) or M.mapRoom
  local name = info.name
  if not name and id and roomExists(id) then name = getRoomName(id) end
  return id, name, info.zone
end

function M.recordLoot(e)
  e.t = os.time()
  e.room, e.roomName, e.area = lootRoom()
  local gold = e.item:match("^([%d,]+) gold coins?$") or e.item:match("^([%d,]+) coins?$")
  if gold then
    local n = tonumber((gold:gsub(",", ""))) or 0
    M.sess.lootGold = (M.sess.lootGold or 0) + n
    return
  end
  M.dbx("INSERT INTO loot (t, who, item, src, n, room, room_name, area) VALUES (%s, %s, %s, %s, %s, %s, %s, %s)",
    e.t, e.who, e.item, e.from, e.count or 1, e.room, e.roomName, e.area)
end

-- learn the game's wording: the replies to your first few get/take commands go to the samples file
M.lootCtxLogged = M.lootCtxLogged or 0
function M.noteLootCommand(cmd)
  if not M.cfg.samples or M.lootCtxLogged >= 20 then return end
  local c = trim(cmd or ""):lower()
  if c:match("^get%s") or c:match("^take%s") or c:match("^loot") or c == "get" then
    M.lootCtx = { cmd = cmd, lines = {} }
  end
end

function M.noteLootContext(l)
  local x = M.lootCtx
  if not x then return end
  x.lines[#x.lines + 1] = l
  if #x.lines >= 8 or isPromptLine() then
    M.lootCtx = nil
    M.lootCtxLogged = M.lootCtxLogged + 1
    local f = io.open(M.samplesFile, "a")
    if f then
      f:write("===== " .. os.date("%Y-%m-%d %H:%M:%S") .. " | kind=lootctx | cmd=" .. x.cmd .. "\n")
      for _, y in ipairs(x.lines) do f:write(y, "\n") end
      f:write("===== end\n\n")
      f:close()
    end
  end
end

function M.lootLines(width, q, all)
  local out, links, rooms = {}, {}, {}
  q = q and trim(q):lower() or ""
  local r1 = M.dbRow("SELECT COUNT(*) AS c FROM loot WHERE t >= %s", M.sess.start or 0)
  local r2 = M.dbRow("SELECT COUNT(*) AS c FROM loot")
  local sessN, total = tonumber(r1 and r1.c) or 0, tonumber(r2 and r2.c) or 0
  local limit = all and 1000 or 30
  -- newest first; the search covers item, who, source, room, area and room number
  local rows = M.dbRows([[SELECT t, who, item, src, n, room, room_name, area FROM loot
    WHERE %s = '' OR instr(lower(item || ' ' || ifnull(who, '') || ' ' || ifnull(src, '') || ' ' || ifnull(room_name, '')
      || ' ' || ifnull(area, '') || ' #' || ifnull(room, '')), %s) > 0
    ORDER BY id DESC LIMIT %s]], q, q, limit + 1)
  local log = {}
  for i = #rows, 1, -1 do
    local r = rows[i]
    log[#log + 1] = { t = tonumber(r.t), who = r.who, item = r.item, from = r.src, count = tonumber(r.n) or 1,
                      room = tonumber(r.room), roomName = r.room_name, area = r.area }
  end
  local title = q ~= "" and ("Loot: " .. q) or "Loot"
  out[1] = header("loot", "", width, title)
  local gold = M.sess.lootGold or 0
  out[#out + 1] = { { C.dim, string.format("%d pickup%s this session, %d logged in all", sessN, sessN == 1 and "" or "s", total) },
                    gold > 0 and { C.num, "  ·  " .. M.commaNum(gold) .. " gold picked up" } or { C.dim, "" } }
  out[#out + 1] = {}
  local shown = 0
  local lastDay
  for i = #log, 1, -1 do
    local e = log[i]
    do
      shown = shown + 1
      if shown > limit then
        out[#out + 1] = { { C.dim, "… more: sbo log loot" .. (q ~= "" and (" " .. q) or "") } }
        break
      end
      local day = os.date("%Y-%m-%d", e.t)
      if day ~= lastDay then
        if lastDay then out[#out + 1] = {} end
        subhead(out, day == os.date("%Y-%m-%d") and "Today" or day)
        lastDay = day
      end
      out[#out + 1] = { { C.dim, "  " .. os.date("%H:%M", e.t) .. "  " },
                        { e.who == "you" and C.slot or C.key, pad(e.who or "?", 10) },
                        { C.item, e.item }, { C.num, (e.count or 1) > 1 and (" x" .. e.count) or "" } }
      local where = {}
      if e.from then where[#where + 1] = "from " .. e.from end
      if e.roomName then where[#where + 1] = e.roomName end
      if e.area and e.area ~= "" then where[#where + 1] = e.area end
      if e.room then where[#where + 1] = "#" .. e.room end
      out[#out + 1] = { { C.dim, "                 " .. (#where > 0 and table.concat(where, " · ") or "room unknown") } }
      if e.room and not rooms[e.room] then
        rooms[e.room] = true
        local id, nm = e.room, e.roomName or ("#" .. e.room)
        links[#links + 1] = { "map: " .. nm .. " #" .. id, function() M.mapShow(id) end }
      end
    end
  end
  if shown == 0 then out[#out + 1] = { { C.dim, q ~= "" and "  nothing logged matches that" or "  nothing picked up yet" } } end
  return out, links
end

-- sbo eq learn: look at every worn item Oven doesn't know yet (the "?" in eq), quietly.
-- sbo eq learn carried: the same for what you carry, and what's inside your containers.
-- Each entry is { name, cmd, inside = container name or nil }; done() runs when the queue is empty.
function M.learnStart(entries, what, done, silent)
  M.learnQueue, M.learnStats, M.learnDone = entries, M.learnStats or { ok = 0, fail = 0 }, done
  if #entries > 0 and not silent then say("looking at " .. #entries .. " " .. what .. (#entries == 1 and "" or "s") .. "…") end
  M.learnNext()
end

function M.learn(arg)
  arg = trim(arg or ""):lower()
  if arg == "inv" or arg == "inventory" or arg == "i" then return M.learnInv() end
  -- then: what to do after (sbo eq learn does worn items, then carried ones)
  local function after() local t = M.learnThen; M.learnThen = nil; if t then t() end end
  if #M.eqNames == 0 then say("type eq first, so Oven knows what you're wearing"); return after() end
  local q, seen = {}, {}
  for _, n in ipairs(M.eqNames) do
    if not M.items[n] and not seen[n] then seen[n] = true; q[#q + 1] = { name = n } end
  end
  if #q == 0 then say("every item you're wearing is already known"); return after() end
  M.learnStats = { ok = 0, fail = 0 }
  M.learnStart(q, "worn item", function() M.learnReport(); M.sendOwn("eq"); after() end)
end

function M.learnReport(extra)
  local st = M.learnStats or { ok = 0, fail = 0 }
  say(string.format("learned %d item%s%s%s", st.ok, st.ok == 1 and "" or "s",
    st.fail > 0 and string.format(" (%d couldn't be looked at)", st.fail) or "", extra or ""))
end

-- a reply read quietly and handed to fn(lines): the next command of that kind
function M.quietly(cmd, kind, fn)
  local mine = { kind = kind, fn = fn }
  M.quietNext = mine
  M.sendOwn(cmd, false)
  -- no reply of that kind? give up on it (mine is taken before sending: the reply can be picked up at once)
  tempTimer(6, function() if M.quietNext == mine then M.quietNext = nil; pcall(fn, nil) end end)
end

-- the item names in an inventory or container list ("(  2) a lime green vial (new)" -> a lime green vial)
function M.listNames(lines)
  local out, seen = {}, {}
  for _, l in ipairs(lines or {}) do
    local t = trim(l)
    local rest = t:match("^%(%s*%d+%)%s*(.+)$") or t
    if l:match("^%s%s%s%s%s%S") or t:match("^%(%s*%d+%)") then
      local n = trim((stripConds(rest)))
      if n ~= "" and not seen[n] then seen[n] = true; out[#out + 1] = n end
    end
  end
  return out
end

local function isContainer(n)
  local it = M.items[n]
  return it and ((it.type or ""):lower():match("container") or it.contents) and true or false
end

function M.learnInv()
  M.learnStats = { ok = 0, fail = 0 }
  M.quietly("inventory", "contents", function(lines)
    if not lines then return say("the game didn't answer inventory - try again") end
    local names = M.listNames(lines)
    if #names == 0 then return say("you aren't carrying anything") end
    local q = {}
    for _, n in ipairs(names) do if not M.items[n] then q[#q + 1] = { name = n } end end
    -- then what's inside each container (some are only known to be containers once looked at)
    M.learnStart(q, "carried item", function() M.learnContainers(names, 1) end)
  end)
end

function M.learnContainers(names, i)
  while names[i] and not isContainer(names[i]) do i = i + 1 end
  local bag = names[i]
  if not bag or M.learnNoInside then
    M.learnNoInside = nil
    M.learnReport()
    return M.sendOwn("inventory")
  end
  M.quietly('look in "' .. bag .. '"', "contents", function(lines)
    local q = {}
    for _, n in ipairs(M.listNames(lines)) do
      if not M.items[n] then q[#q + 1] = { name = n, inside = bag, cmd = 'look "' .. n .. '" in "' .. bag .. '"' } end
    end
    M.learnStart(q, "item in " .. bag, function() M.learnContainers(names, i + 1) end)
  end)
end

function M.learnNext()
  if not M.learnQueue then return end
  local e = table.remove(M.learnQueue, 1)
  if not e then
    M.learnQueue = nil
    local done = M.learnDone
    M.learnDone = nil
    if done then done() end
    return
  end
  M.learning = { name = e.name, entry = e, ok0 = M.learnStats.ok }
  local mine = M.learning
  M.sendOwn(e.cmd or ('look "' .. e.name .. '"'), false)
  -- no reply at all? move on
  tempTimer(5, function()
    if M.learning == mine and not mine.started then
      M.learning = nil
      M.learnStats.fail = M.learnStats.fail + 1
      pcall(M.learnResult, e, false)
      M.learnNext()
    end
  end)
end

-- the first item looked at inside a container decides whether the game allows it at all
function M.learnResult(entry, ok)
  if not entry or not entry.inside then return end
  if ok then M.learnInsideOk = true return end
  if M.learnInsideOk then return end
  -- the game won't show items in containers: drop the rest, say so once
  local kept = {}
  for _, e in ipairs(M.learnQueue or {}) do
    if e.inside then M.learnStats.fail = M.learnStats.fail + 1 else kept[#kept + 1] = e end
  end
  M.learnQueue = kept
  M.learnNoInside = true
  say("the game won't let Oven look at items while they're inside a container - take them out (or look at them in the bag yourself) to add them")
end


-- Picking something up: GMCP doesn't describe items, so Oven looks at a new one quietly (once you're
-- out of the fight and the game is idle), then says so in the main window if it beats what you wear.
local function pickupName(item)
  local n = trim(item or ""):gsub("^%d+ of ", "")
  if n:match("^[%d,]+ gold coins?$") or n:match("^[%d,]+ coins?$") or n == "" then return nil end
  return n
end

function M.notePickup(loot)
  if loot.who ~= "you" or not M.cfg.pickupLook then return end
  local n = pickupName(loot.item)
  if not n then return end
  -- it's carried now, for sbo upgrades
  local c = M.cfg.carried
  if c and c.inv then
    local have = false
    for _, x in ipairs(c.inv) do if x == n then have = true end end
    if not have then c.inv[#c.inv + 1] = n end
  end
  if M.items[n] then return M.pickupVerdict(M.items[n]) end
  M.pickupPending = M.pickupPending or {}
  for _, e in ipairs(M.pickupPending) do if e.name == n then return end end
  M.pickupPending[#M.pickupPending + 1] = { name = n, pickup = true }
end

-- in a fight: one Oven is following (combat mode mxp rounds), or an enemy the game named in the last
-- 30 seconds. Not char.status's position: the game sends status rarely, and the last one is often from
-- the middle of a fight hours ago ("fighting" long after it ended).
function M.fighting()
  if next(M.fights or {}) then return true end
  local st = M.gmcpGet and M.gmcpGet("char.status")
  if type(st) ~= "table" or not st.enemy or st.enemy == "_empty" or st.enemy == "" then return false end
  return (M.live.statusAt or 0) >= os.time() - 30
end

-- one look at a time, and only once you've stopped typing for 2 seconds (they share the game's command
-- queue with yours, so they wait for a quiet moment); never mid-fight, never before you're playing
function M.pickupFlush(promptLine)
  local q = M.pickupPending
  if not q or #q == 0 then M.pickupPending = nil return end
  promptLine = promptLine or M.lastStatusPrompt
  if M.busyWhy(promptLine) then return end   -- the next prompt tries again
  if not M.userIdle(2) then
    -- you're typing: try again after a quiet spell (a prompt may not come)
    if not M.pickupRetry then
      M.pickupRetry = tempTimer(2.2, function() M.pickupRetry = nil; pcall(M.pickupFlush) end)
    end
    return
  end
  local e = table.remove(q, 1)
  if #q == 0 then M.pickupPending = nil end
  M.learnStats = { ok = 0, fail = 0 }
  M.learnStart({ e }, "picked-up item", function()
    if M.items[e.name] then pcall(M.pickupVerdict, M.items[e.name]) end
    if M.pickupPending then tempTimer(1, function() pcall(M.pickupFlush) end) end
  end, true)
end

-- one line, only for an upgrade: "picked up a sturdy staff: gear score 23.5, +5.5 over a bo staff (sbo compare)"
function M.pickupVerdict(it)
  local _, w = M.activeBuild()
  local worn = M.wornLike(it, w)
  if not worn then return end
  local sc, ws = M.gearScore(it, w), M.gearScore(worn, w)
  if not sc or not ws or sc <= ws then return end
  local d = math.floor((sc - ws) * 10 + 0.5) / 10
  M.pickupLast = { it.name, worn.name }
  say(string.format("picked up %s: gear score %s, +%s over your %s (sbo compare %s vs %s)", it.name, sc, d, worn.name, it.name, worn.name))
end


-- numeric setting argument: a number, or blank for the default
function M.numArg(v, key)
  v = trim(v or "")
  if v == "" then return M.defaults[key] end
  local n = tonumber(v)
  if n and n >= 0 then return n end
end

function M.legacyCommand(args)
  args = trim(args or "")
  local a, b = args:match("^(%S*)%s*(.-)$")
  a = a:lower()
  local onoff  -- (careful: `x and false or nil` is always nil in Lua)
  if b == "on" then onoff = true elseif b == "off" then onoff = false end
  if a == "" then return M.help()
  elseif a == "help" then return M.help(b)
  elseif a == "on" or a == "off" then M.cfg.enabled = (a == "on"); say("capturing " .. a)
  elseif a == "main" and (b == "replace" or b == "keep" or b == "off") then
    M.cfg.main = (b == "off") and "keep" or b; say("main window: " .. M.cfg.main)
  elseif a == "window" and onoff ~= nil then
    M.cfg.window = onoff; M.showWindow(onoff); say("Inspector window " .. b)
  elseif a == "samples" and onoff ~= nil then
    M.cfg.samples = onoff; say("sample logging " .. b .. " (" .. M.samplesFile .. ")")
  elseif a == "prompt" then
    M.cfg.promptPattern = b; say("prompt pattern set to " .. string.format("%q", b))
  elseif a == "font" and M.numArg(b, "fontSize") then
    M.cfg.fontSize = M.numArg(b, "fontSize")
    if M.viewPg and M.container then M.viewShow() end
    say("Inspector and help window font size " .. M.cfg.fontSize .. (b == "" and " (default)" or ""))
  elseif a == "clear" then M.viewHist = {}; M.viewPos = nil; if M.container then M.viewShow() end
  elseif a == "raw" then
    local last = M.history[#M.history]
    if not last then return say("nothing captured yet") end
    for i, l in ipairs(last.plain) do
      if last.decho[i] then decho(last.decho[i] .. "\n") else echo(l .. "\n") end
    end
  elseif a == "update" then return M.update(b)
  elseif a == "compare" then
    if b == "" then
      local n = #M.recent
      if n < 2 then return say("look at two items first") end
      M.compareNames(M.recent[n - 1], M.recent[n])
    else
      local qa, qb = b:match("^(.-)%s+vs%.?%s+(.+)$")
      if not qa then qa, qb = b:match("^(.-)%s*|%s*(.+)$") end
      if not qa then return say("usage: sbo compare <item> vs <item>") end
      M.compareNames(qa, qb)
    end
    return
  elseif a == "pin" then return M.pin(b ~= "" and b or nil)
  elseif a == "unpin" then M.pinned = nil; M.saveItems(); say("unpinned"); return
  elseif a == "tabs" and (b == "auto on" or b == "auto off") then
    M.cfg.tabAuto = (b == "auto on")
    say(M.cfg.tabAuto and "tabs switch by themselves: whatever arrives comes to the front"
      or "tabs stay where you put them: a tab with something new gets a • (sbo commands like sbo log kills still switch)")
  elseif a == "tabs" and onoff ~= nil then
    M.cfg.tabs = onoff
    if M.container then M.applyTabs(); M.viewShow() end
    say(onoff and "tabs on: Inspector | Help | Log in one window" or "tabs off: help pages get their own window again")
  elseif a == "layout" and (b == "save" or b == "reset" or b == "restore") then
    if b == "save" then M.panelsSave(true); return say("panel layout saved - it's also saved by itself a few seconds after you move a panel")
    elseif b == "restore" then M.panelsRestore(); return say("panels put back where you saved them")
    else M.panelsReset(); return say("panels back to Oven's default places") end
  elseif a == "combat" and (onoff ~= nil or b:match("^bar %a+$") or b:match("^lines %a+$")) then
    local what, v = b:match("^(%a+) (%a+)$")
    if not what then what, v = "both", b end
    if v ~= "on" and v ~= "off" then return say("sbo config combat|combat.bar|combat.lines on|off") end
    if what == "bar" or what == "both" then M.cfg.combatBar = (v == "on") end
    if what == "lines" or what == "both" then M.cfg.combatLines = (v == "on") end
    if not M.cfg.combatBar then M.cbarShown = false; pcall(M.layoutBar) end
    say(string.format("combat mode mxp: target bar %s, round lines and summaries %s",
      M.cfg.combatBar and "on" or "off", M.cfg.combatLines and "on" or "off"))
  elseif a == "chat" then return M.chatCommand(b)
  elseif a == "tab" and (b == "inspector" or b == "help" or b == "log" or b == "chat" or b == "notes") then
    M.createWindow(); M.container:show()
    M.tabShow(b == "inspector" and "view" or b)
    return
  elseif a == "mirror" then
    local MIRROR = { inspector = "view", view = "view", help = "help", log = "log", chat = "chat" }
    local what, v = b:lower():match("^(%a+)%s+(%a+)$")
    local key = what and MIRROR[what]
    if key and (v == "on" or v == "off") then
      M.cfg.mirror[key] = (v == "on")
      if key == "help" and v == "on" then M.cfg.helpWindow = true end
    elseif b ~= "" then
      return say("sbo config inspector|help|log|chat.mirror on|off")
    end
    local m = M.cfg.mirror
    local function st(x) return x and "on" or "off" end
    say("also on the main screen - inspector " .. st(m.view) .. " · help " .. st(m.help) .. " · log " .. st(m.log)
      .. " · chat " .. st(m.chat) .. "  (sbo config <tab>.mirror on|off)")
  elseif a == "helpwindow" and b == "both" then
    M.cfg.helpWindow, M.cfg.mirror.help = true, true
    say("help pages: in the help window and on the main screen (same as sbo config help.mirror on)")
  elseif a == "helpwindow" and onoff ~= nil then
    M.cfg.mirror.help = false
    M.cfg.helpWindow = onoff
    if not onoff and M.helpContainer then M.helpContainer:hide() end
    say("help window " .. b)
  elseif a == "slots" and (b == "short" or b == "full") then
    M.cfg.slotNames = b; say("slot names: " .. b)
  elseif a == "learn" then return M.learn(b)
  elseif a == "run" then return M.mapRun(b)
  elseif a == "signposts" or a == "signpost" or a == "runs" then
    local v = b:lower():match("^look%s+(%a+)$")
    if v == "on" or v == "off" then
      M.cfg.signLook = (v == "on"); M.saveSettings()
      return say("looking at new signposts: " .. v)
    end
    return M.runList()
  elseif a == "build" then return M.buildCommand(b)
  elseif a == "upgrades" or a == "upgrade" then
    local n = tonumber(b:match("^compare%s+(%d+)$") or "")
    if n then
      local u = (M.lastUpgrades or {})[n]
      if not u then return say("no upgrade #" .. n .. " - type sbo upgrades first") end
      return M.compareNames(u.cur, u.best)
    end
    M.viewOut(M.upgradeLines(M.cfg.window and M.viewCols() or columns("main"), b == "all"))
    return
  elseif a == "mark" then if b == "" then return M.listMarks() end return M.markRoom(b)
  elseif a == "marks" then return M.listMarks()
  elseif a == "unmark" then return M.unmarkRoom(b)
  elseif a == "record" then
    local W = M.win
    if b == "off" or b == "stop" then
      local n = M.recordStop("off")
      return say(n and ("recording stopped: " .. n .. " blocks saved to oven_record.txt") or "not recording")
    elseif b:match("^save%s+all") then
      -- everything still in memory, even what was written before
      local note = trim(b:gsub("^save%s+all", ""))
      M.win.savedSeq = 0
      local n = M.windowSave(note ~= "" and ("sbo debug record save all: " .. note) or "sbo debug record save all")
      return say("saved all " .. n .. " blocks still in memory to oven_record.txt")
    elseif b:match("^save") then
      local note = trim(b:gsub("^save", ""))
      local n = M.windowSave(note ~= "" and ("sbo debug record save: " .. note) or "sbo debug record save")
      if n == 0 then return say("nothing new since the last save - it's all in oven_record.txt") end
      return say("saved the last " .. n .. " blocks of game output to oven_record.txt")
    elseif b:match("^window") then
      local v = b:match("^window%s+(%S+)")
      if v then
        M.cfg.recWindow = (v == "off") and 0 or (tonumber(v) or M.defaults.recWindow)
        while #W.blocks > M.cfg.recWindow do table.remove(W.blocks, 1) end
        M.saveSettings()
      end
      return say("keeping the last " .. M.cfg.recWindow .. " blocks of game output in memory (now " .. #W.blocks
        .. ") - sbo debug record save writes them out, and they're saved when you die (sbo config record.window N)")
    elseif b == "" or tonumber(b) then
      local mins = tonumber(b) or 30
      M.recordStart(mins)
      return say("recording every block as it happens, with your commands and GMCP, for " .. mins
        .. " minutes to oven_record.txt (sbo debug record stop stops it). Passwords aren't saved.")
    end
    return say("sbo debug record save [note] | sbo debug record save all | sbo debug record start [minutes] | sbo debug record stop | sbo config record.window N")
  elseif a == "gmcp" then
    local names = M.gmcpDump()
    if #names == 0 then return say("the game hasn't sent any GMCP yet") end
    return say("GMCP packages: " .. table.concat(names, ", ") .. " - written in full to oven_gmcp.txt")
  elseif a == "deaths" then
    M.logOut(M.deathLines)
    return
  elseif a == "shops" or a == "shop" then
    return M.viewOut(M.shopLines(M.cfg.window and M.viewCols() or columns("main"), b))
  elseif a == "loot" then
    if b == "clear" then M.dbx("DELETE FROM loot"); return say("loot log cleared") end
    local all = b == "all" or b:match("^all%s") ~= nil
    local q = all and b:gsub("^all%s*", "") or b
    M.logOut(function(w) return M.lootLines(w, q, all) end)
    return
  elseif a == "kills" then
    if b == "reset" then M.sess.killBook = {}; return say("this session's kill list cleared")
    elseif b == "clear" then M.dbx("DELETE FROM kills"); return say("all-time kill list cleared") end
    M.logOut(function(w) return M.killLines(w, b == "all") end)
    return
  elseif a == "quest" or a == "quests" then
    local sub, val = b:match("^(%S*)%s*(.-)$")
    if sub == "pin" and val ~= "" then M.questPin(val, true); return say("pinned " .. val .. " to the quest tracker")
    elseif sub == "unpin" and val ~= "" then M.questPin(val, false); return say("unpinned " .. val)
    elseif sub == "autopin" and (val == "on" or val == "off") then
      M.cfg.questAutoPin = (val == "on"); M.saveSettings()
      return say(val == "on" and "quests you take with quest request are pinned to the quest HUD"
        or "quest request no longer pins the new quest")
    elseif sub == "refresh" then M.questRefresh(val ~= "" and val or "all"); return
    elseif sub == "go" or sub == "run" then return M.questGo(val)
    elseif sub == "hide" then
      if M.questHud then M.questHud:hide() end
      for _, c in ipairs(M.questCards or {}) do c:hide() end
      return
    elseif sub == "hud" and (val == "left" or val == "right") then
      M.cfg.questHudSide = val; M.cfg.questHudPos = nil; M.saveSettings(); M.drawQuestTracker(); return say("quest HUD on the " .. val)
    elseif sub == "hud" and val:match("^opacity") then
      local n = val:match("^opacity%s*(%d*)%%?$")
      if n == nil then return say("usage: sbo config quest.opacity <0-100>") end
      M.cfg.questHudOpacity = (n == "") and 100 or math.max(0, math.min(100, tonumber(n)))
      M.saveSettings(); M.drawQuestTracker()
      return say("quest HUD opacity " .. M.cfg.questHudOpacity .. "%" .. (n == "" and " (default)" or ""))
    elseif sub == "hud" and (val == "blurb on" or val == "blurb off") then
      M.cfg.questHudBlurb = (val == "blurb on"); M.saveSettings(); M.drawQuestTracker()
      return say("quest descriptions (hints) in the HUD " .. (M.cfg.questHudBlurb and "on" or "off"))
    elseif sub == "hud" and val == "reset" then
      M.cfg.questHudPos = nil; M.saveSettings(); M.drawQuestTracker(); return say("quest HUD back in its corner")
    elseif sub == "show" or sub == "" then M.drawQuestTracker()
      if not next(M.cfg.questPins or {}) then say("no quests pinned: type quest info, then click pin (or sbo quest pin <id|all>)") end
      return
    end
    return say("sbo quest pin|unpin <id|all> · sbo quest go [id] · sbo quest refresh [id]")
  elseif a == "map" then
    if b == "on" then
      M.cfg.map = true; M.saveSettings(); M.mapStart()
      return say("map: following you by room number; double-click a room to walk there (sbo stop cancels)")
    elseif b == "off" then
      M.cfg.map = false; M.saveSettings(); M.mapStop(); return say("map following and click-to-walk off")
    elseif b == "stop" then
      if M.running and M.running.target then M.running.target = nil; M.walk = nil; return say("walk cancelled (the run itself goes on until it stops)") end
      if M.walk then M.walk = nil; return say("walk cancelled") end
      return say("not walking")
    elseif b:match("^find%s") or b:match("^search%s") then
      return M.mapFind(b:gsub("^%a+%s+", ""))
    elseif b:match("^walk%s+%d+$") then
      return M.mapWalkTo(tonumber(b:match("(%d+)$")))
    elseif b:match("^show%s+%d+$") then
      return M.mapShow(tonumber(b:match("(%d+)$")))
    elseif b == "card on" or b == "card off" then
      M.cfg.mapCard = (b == "card on"); M.saveSettings()
      return say("room card on click " .. (M.cfg.mapCard and "on" or "off"))
    elseif b == "panel on" or b == "panel off" then
      M.cfg.mapPanel = (b == "panel on"); M.saveSettings(); M.showMapPanel(M.cfg.mapPanel)
      if M.cfg.mapPanel and not M.cfg.map then M.cfg.map = true; M.saveSettings(); M.mapStart() end
      return say("map panel " .. (M.cfg.mapPanel and "on: drag/resize it, or right-click its title for 'attach to border'" or "off"))
    elseif b:match("^load") then
      local file = trim(b:gsub("^load", "")); if file == "" then file = getMudletHomeDir() .. "/map/mm_map.dat" end
      if not io.exists(file) then return say("map file not found: " .. file) end
      local ok = loadMap(file)
      say(ok and ("loaded " .. file) or ("couldn't load " .. file))
      if M.cfg.map then M.onRoom() end
      return
    end
    return say("map " .. (M.cfg.map and "on" or "off") .. (M.mapRoom and (" · you're in room " .. M.mapRoom) or "")
      .. "  (sbo config map on|off · sbo map load [file])")
  elseif a == "session" then
    if b == "reset" then M.sess = { start = os.time(), gained = 0 }; say("session counters reset"); return end
    M.logOut(M.sessionLines)
    return
  elseif a == "gamecolors" and onoff ~= nil then
    M.cfg.gameColors = onoff; say("game colours on item names " .. b)
  elseif a == "eqstats" and onoff ~= nil then
    M.cfg.eqStats = onoff; say("item stats column in eq: " .. b)
  elseif a == "donation" and onoff ~= nil then
    M.cfg.showDonation = onoff
    say("empty donation-only slots (amulet, face, aura) " .. (onoff and "shown" or "hidden") .. " in eq")
  elseif a == "empty" and onoff ~= nil then
    M.cfg.showEmpty = onoff; say("empty slots in eq: " .. b)
  elseif a == "autocompare" and onoff ~= nil then M.cfg.autocompare = onoff; say("auto-compare " .. b)
  elseif a == "pickup" then
    local v = trim(b or ""):lower():gsub("^look%s*", "")
    if v == "on" or v == "off" then M.cfg.pickupLook = (v == "on"); M.saveSettings() end
    say("looking at new items you pick up: " .. (M.cfg.pickupLook and "on" or "off") .. "  (sbo config eq.pickuplook on|off)")
  elseif a == "items" then
    say(#M.recent .. " remembered items (most recent last):")
    for _, n in ipairs(M.recent) do
      local it = M.items[n]
      cecho(string.format("  <white>%s<reset>  <dim_grey>%s%s<reset>\n", n, it and it.type or "?",
        (it and it.worn) and (", " .. it.worn) or ""))
    end
    return
  elseif a == "bar" then
    local sub, val = b:match("^(%S*)%s*(.-)$")
    if sub == "on" or sub == "off" then M.cfg.bar = (sub == "on"); M.showBar(M.cfg.bar); say("prompt bar " .. sub)
    elseif sub == "raw" or sub == "gauges" then M.cfg.barMode = sub; M.drawBar(); say("prompt bar mode " .. sub)
    elseif sub == "session" and (val == "on" or val == "off") then
      M.cfg.barSession = (val == "on"); M.showSessionBar(M.cfg.barSession); M.drawBar()
      say("session details " .. val .. (M.cfg.bar and "" or " (they show when the bar is on: sbo config bar on)"))
    elseif sub == "session" and (val == "full" or val == "short") then
      M.cfg.barSessionStyle = val; M.drawBar()
      say("session details: " .. (val == "short" and "just exp per hour" or "time, kills/deaths and exp per hour"))
    elseif sub == "session" and (val == "top" or val == "bottom") then
      M.cfg.barSessionPos = val; M.layoutBar(); M.drawBar()
      say("when they don't fit on the bar, session details go at the " .. val .. (val == "top" and " of the screen" or ", under the bar"))
    elseif sub == "bg" then
      local r, g, b = val:match("^(%d+)[%s,]+(%d+)[%s,]+(%d+)$")
      if val == "" then M.cfg.barBg = { unpack(M.defaults.barBg) }
      elseif r then M.cfg.barBg = { math.min(255, tonumber(r)), math.min(255, tonumber(g)), math.min(255, tonumber(b)) }
      else return say("usage: sbo bar bg <red> <green> <blue>  (0-255; nothing = default)") end
      M.applyBarBg(); M.drawBar()
      say(string.format("prompt bar background %d %d %d%s", M.cfg.barBg[1], M.cfg.barBg[2], M.cfg.barBg[3], val == "" and " (default)" or ""))
    elseif sub == "blanks" and (val == "on" or val == "off") then
      M.cfg.barBlank = (val == "off")
      say("blank line before each prompt " .. (val == "on" and "kept" or "removed"))
    elseif sub == "width" and M.numArg(val, "barWidth") then
      M.cfg.barWidth = M.numArg(val, "barWidth"); M.drawBar()
      say("gauge width " .. M.cfg.barWidth .. (val == "" and " (default)" or ""))
    elseif sub == "lines" and M.numArg(val, "barLines") then
      M.cfg.barLines = M.numArg(val, "barLines"); M.layoutBar()
      say("prompt bar lines " .. M.cfg.barLines .. (val == "" and " (default)" or ""))
    elseif sub == "font" and M.numArg(val, "barFont") then
      M.cfg.barFont = M.numArg(val, "barFont")
      M.layoutBar(); M.drawBar()
      say("prompt bar font " .. (M.cfg.barFont > 0 and M.cfg.barFont or ("same as main window (" .. M.barFontSize() .. ")"))
        .. (val == "" and " (default)" or ""))
    else return M.help() end
  else return M.help() end
  M.saveSettings()
end

---------------------------------------------------------------------------
-- The sbo commands, as a tree: one word per part of the screen (inspector, help, log, chat, quest, map) plus eq, window, version,
-- debug), go/stop/config at the top, and every setting under sbo config. Any unique start of a
-- word works at every level ("sbo e up" = "sbo eq upgrades"); when a start fits more than one,
-- Oven lists them instead of guessing. The old commands (0.50 and before) still work.
---------------------------------------------------------------------------
local L = function(cmd) return function() return M.legacyCommand(cmd) end end
local function legacy(cmd) return M.legacyCommand(cmd) end

-- each entry: name, args (shown), desc, run(rest); a group has subs (and may have run for no sub)
M.CMDS = {
  { name = "go", args = "{what}", desc = "walk/run to a trainer, shop, quest, NPC, room #, bookmark, or a where-is feature",
    run = function(r)
      if r == "" then return say("sbo go {what}: a trainer, shop, quest, NPC name, room #, bookmark or signpost run") end
      if r:lower() == "stop" then return M.stopAll() end
      return M.mapRun(r)
    end },
  { name = "stop", desc = "stop a walk, or anything Oven is doing for you", run = function() return M.stopAll() end },
  { name = "eq", desc = "equipment and items: compare, upgrades, learn, builds (shown in the Inspector)", subs = {
    { name = "compare", args = "[{a} vs {b}]", desc = "the last two items looked at, or two by name",
      run = function(r)
        local rest = r:match("^against%s*(.-)$")
        if rest then return M.compareAgainst(rest) end
        return legacy("compare " .. r)
      end },
    { name = "compare against", args = "[{item}]", desc = "compare every look to one item; no item: stop", listOnly = true },
    { name = "upgrades", args = "[all|{n}]", desc = "best upgrade per slot (all: anything seen; n: compare it)",
      run = function(r)
        if tonumber(r) then return legacy("upgrades compare " .. r) end
        return legacy("upgrades " .. r)
      end },
    { name = "learn", args = "[worn|carried]", desc = "look at items Oven doesn't know yet (both when left off)",
      run = function(r)
        local w = r:lower()
        if w ~= "" and ("worn"):sub(1, #w) == w then return M.learn("") end
        if w ~= "" and (("carried"):sub(1, #w) == w or w == "inv") then return M.learnInv() end
        M.learnThen = function() M.learnInv() end
        return M.learn("")
      end },
    { name = "items", desc = "the items Oven remembers", run = L("items") },
    { name = "build", args = "[{name}|set|reset|auto]", desc = "gear-score weights (set: a stat and its weight)",
      run = function(r) return legacy("build " .. r) end },
  } },
  { name = "quest", desc = "the quest panel: pin quests, go to the next step", run = function() return M.questShow() end, subs = {
    { name = "pin", args = "{id|all}", desc = "put quests on the quest HUD", run = function(r) return legacy("quest pin " .. r) end },
    { name = "unpin", args = "{id|all}", desc = "take them off", run = function(r) return legacy("quest unpin " .. r) end },
    { name = "go", args = "[{id}]", desc = "to the next step of a quest", run = function(r) return legacy("quest go " .. r) end },
    { name = "refresh", args = "[{id}]", desc = "re-check pinned quests with the game", run = function(r) return legacy("quest refresh " .. r) end },
  } },
  { name = "map", desc = "the map panel: find rooms, shops, signposts, bookmarks", run = function() return M.mapPanelShow() end, subs = {
    { name = "find", args = "{what|#}", desc = "NPCs, tags, rooms, nearest first (#: centre the map)",
      run = function(r) return M.placesFind(r) end },
    { name = "shops", args = "[{item}]", desc = "shops listed (by you, or when you stop in one), or who sells an item",
      run = function(r) return legacy("shops " .. r) end },
    { name = "signposts", desc = "signpost runs and where each ends", run = function() return M.runList() end },
    { name = "mark", args = "[{name}]", desc = "bookmark this room; no name: list them",
      run = function(r) return legacy("mark " .. r) end },
    { name = "unmark", args = "{name}", desc = "remove a bookmark", run = function(r) return legacy("unmark " .. r) end },
    { name = "highlight", args = "[{what}]", desc = "light up every room with it (trainers; a traveler's path; \"trainer in rune\"); nothing: clear",
      run = function(r) return M.mapHighlightAll(r) end },
    { name = "load", args = "[{file}]", desc = "load a map file (map/mm_map.dat)", run = function(r) return legacy("map load " .. r) end },
  } },
  { name = "inspector", desc = "the Inspector tab: game layouts, comparisons, lists", run = function() return M.windowTab("inspector") end, subs = {
    { name = "clear", desc = "empty its history", run = L("clear") },
  } },
  { name = "log", desc = "the Log tab: kills, loot, deaths and this session", run = L("session"), subs = {
    { name = "kills", desc = "what you've killed, with counts and exp", run = L("kills all") },
    { name = "loot", args = "[{text}]", desc = "what was picked up and where; text searches it",
      run = function(r) return legacy("loot all " .. r) end },
    { name = "deaths", desc = "your last deaths, with what led up to them", run = L("deaths") },
    { name = "session", desc = "exp per hour, time and kills to the next level", run = L("session") },
    { name = "reset", desc = "start a fresh session (kills, exp per hour, gold)", run = L("session reset") },
    { name = "clear", args = "{kills|loot}", desc = "wipe all-time history (asks first)", run = function(r) return M.logClear(r) end },
  } },
  { name = "chat", args = "[{channel}|all]", desc = "the Chat tab: one channel, or all",
    run = function(r) return M.chatCommand(r) end, rest = function(r) return M.chatCommand(r) end, subs = {
    { name = "mute", args = "{channel}", desc = "keep a channel out of All", run = function(r) return M.chatCommand("mute " .. r) end },
    { name = "unmute", args = "{channel}", desc = "bring it back", run = function(r) return M.chatCommand("unmute " .. r) end },
    { name = "remove", args = "{channel}", desc = "drop a channel's chip", run = function(r) return M.chatCommand("forget " .. r) end },
    { name = "clear", desc = "empty the Chat tab", run = function() return M.chatCommand("clear") end },
  } },
  { name = "notes", desc = "the Notes tab: notes you keep, each with where you were",
    run = function() return M.notesShow() end, subs = {
    { name = "add", args = "{text}", desc = "keep a note (or type it in the tab's box)", run = function(r)
      if trim(r) == "" then return say("sbo notes add {text}") end
      M.noteAdd(r); M.notesShow() end },
    { name = "find", args = "{text}", desc = "only the notes with it", run = function(r) return M.notesShow(r) end },
    { name = "remove", args = "{n}", desc = "remove note number n", run = function(r) return M.noteRemove(r) end },
  } },
  { name = "help", args = "[{group}|all]", desc = "the Help tab: this menu, a group's commands, or all of them",
    run = function(r) return M.help(r) end },
  { name = "window", desc = "where the panels sit", rest = function(r) return M.window051(r) end, subs = {
    { name = "restore", desc = "panels back where you put them", run = L("layout restore") },
    { name = "reset", desc = "panels back to Oven's defaults", run = L("layout reset") },
  } },
  { name = "version", desc = "the version you have; update to the newest",
    run = function() return M.versionInfo() end, subs = {
    { name = "update", args = "[force|{file}]", desc = "get the newest version, settings kept (force: reinstall; or a local .mpackage)",
      run = function(r) return M.update(r) end },
  } },
  { name = "debug", desc = "raw output, GMCP and recordings, for fixing things", subs = {
    { name = "raw", desc = "the last output exactly as the game sent it", run = L("raw") },
    { name = "gmcp", desc = "what the game sends over GMCP (written to oven_gmcp.txt)", run = L("gmcp") },
    { name = "state", desc = "what Oven is busy with, and why it did (or didn't) do things by itself (oven_state.txt)",
      run = function() return M.debugState() end },
    { name = "samples", args = "{on|off}", desc = "log raw output to oven_samples.txt", run = function(r) return legacy("samples " .. r) end },
    { name = "record", args = "{start [minutes] | stop | save [note]}", desc = "record game output to oven_record.txt",
      run = function(r)
        local v, rest = r:match("^(%S*)%s*(.-)$")
        v = v:lower()
        if v ~= "" and ("start"):sub(1, #v) == v then return legacy("record " .. rest) end
        if v ~= "" and ("stop"):sub(1, #v) == v and #v >= 3 then return legacy("record off") end
        if v ~= "" and ("save"):sub(1, #v) == v and #v >= 2 then return legacy("record save " .. rest) end
        return say("sbo debug record start [minutes] · sbo debug record stop · sbo debug record save [note]")
      end },
  } },
  { name = "config", args = "[{name} {value}]", desc = "every setting with its value, grouped; or change one",
    run = function(r) return M.config(r) end },
  -- shortcuts (listed under the menu) and other names for things
  { name = "compare", shortcut = "eq compare", run = function(r) return M.CMD_RUN({ "eq", "compare" }, r) end },
  { name = "upgrades", shortcut = "eq upgrades", run = function(r) return M.CMD_RUN({ "eq", "upgrades" }, r) end },
  { name = "set", alias = "config", run = function(r) return M.config(r) end },
  { name = "run", alias = "go", run = function(r) return M.mapRun(r) end },
  { name = "update", alias = "version update", run = function(r) return M.update(r) end },
  { name = "gear", alias = "eq", prefixOK = true, run = function(r) return M.renamed("gear", "eq", r) end },
  { name = "places", alias = "map", prefixOK = true, run = function(r) return M.renamed("places", "map", r:gsub("^loadmap", "load")) end },
}

-- the entry a word means among siblings: an exact name, else the one name it's the start of.
-- Aliases only by their full name. Returns entry, or nil plus the names it could be.
local function pick(list, w)
  w = (w or ""):lower()
  if w == "" then return nil, {} end
  for _, e in ipairs(list) do if e.name == w and not e.listOnly then return e end end
  local hits = {}
  for _, e in ipairs(list) do
    if (not e.alias or e.prefixOK) and not e.listOnly and e.name:sub(1, #w) == w then hits[#hits + 1] = e end
  end
  if #hits == 1 then return hits[1] end
  local names = {}
  for _, e in ipairs(hits) do names[#names + 1] = e.name end
  return nil, names
end
M.cmdPick = pick

-- the shortest start of each name that only it has (shown highlighted in the lists)
local function shortest(list, e)
  for n = 1, #e.name do
    local pre, ok = e.name:sub(1, n), true
    for _, o in ipairs(list) do
      if o ~= e and (not o.alias or o.prefixOK) and not o.listOnly and o.name:sub(1, n) == pre then ok = false; break end
    end
    if ok then return n end
  end
  return #e.name
end
M.cmdShortest = shortest

-- the old commands: what each is now (a tip, once a session, when you type one)
local OLD = {
  on = "config formatting on", off = "config formatting off", main = "config main", samples = "debug samples",
  prompt = "config prompt", font = "config font", clear = "inspector clear", raw = "debug raw",
  pin = "eq compare against {item}", unpin = "eq compare against", tabs = "config tabs / tabs.auto",
  layout = "window restore / reset", combat = "config combat / combat.bar / combat.lines", tab = "inspector / help / log / chat",
  mirror = "config {tab}.mirror", helpwindow = "config help.window", slots = "config eq.slots", learn = "eq learn",
  signposts = "map signposts", signpost = "map signposts", runs = "map signposts", build = "eq build",
  mark = "map mark", marks = "map mark", unmark = "map unmark", record = "debug record start|stop|save",
  gmcp = "debug gmcp", deaths = "log deaths", kills = "log kills", loot = "log loot", session = "log session / log reset",
  shops = "map shops", shop = "map shops", gamecolors = "config eq.gamecolors", eqstats = "config eq.stats",
  donation = "config eq.donation", empty = "config eq.empty", autocompare = "config eq.autocompare",
  pickup = "config eq.pickuplook", items = "eq items", bar = "config bar…", quests = "quest",
  upgrade = "eq upgrades",
  map = function(b)
    local w = (b:match("^(%S*)") or ""):lower()
    if w == "search" then return "map find" elseif w == "walk" then return "go {#}"
    elseif w == "show" then return "map find {#}" elseif w == "stop" then return "stop" end
    return "config map / map.panel / map.card"
  end,
  quest = function(b)
    local w = (b:match("^(%S*)") or ""):lower()
    if w == "autopin" then return "config quest.autopin" elseif w == "hud" then return "config quest.side / quest.opacity / quest.blurb"
    elseif w == "show" or w == "hide" then return "config quest.hud on|off" end
  end,
  chat = function(b) if b:match("^forget") then return "chat remove" end end,
  window = function(b) if b == "on" or b == "off" then return "config window " .. b end end,
  update = function(b) if b:match("^auto") then return "config update.auto" end return "version update" end,
}
M.OLD_COMMANDS = OLD

function M.oldCommand(a, args, b)
  local hint = OLD[a]
  if type(hint) == "function" then hint = hint(b) end
  if hint and M.typing then
    M.oldTold = M.oldTold or {}
    if not M.oldTold[a] then
      M.oldTold[a] = true
      say("tip: that's sbo " .. hint .. " now (the old form still works)")
    end
  end
  return M.legacyCommand(args)
end

-- run the entry at path with the rest of the line
function M.CMD_RUN(path, rest)
  local list, e = M.CMDS, nil
  for _, n in ipairs(path) do e = pick(list, n); list = e and e.subs or {} end
  if e and e.run then return e.run(rest or "") end
end

function M.typedCommand(args)
  M.typing = true
  local ok, err = pcall(M.command, args)
  M.typing = false
  if not ok then say("that command failed: " .. tostring(err)) end
end

function M.command(args)
  args = trim(args or "")
  if args == "" then return M.menu() end
  local a, b = args:match("^(%S+)%s*(.-)$")
  local al = a:lower()
  -- 1. a new command by its full name; 2. an old one; 3. the start of a new one
  local e = nil
  for _, x in ipairs(M.CMDS) do if x.name == al then e = x; break end end
  if not e and OLD[al] ~= nil then return M.oldCommand(al, args, b) end
  if not e then
    local maybe
    e, maybe = pick(M.CMDS, al)
    if not e then
      if #maybe > 0 then return M.choose("sbo " .. a, maybe, "") end
      return say("no command '" .. a .. "' - type sbo for the list")
    end
  end
  if not e.subs then return e.run(b) end
  -- a group: its sub-command, or the group's own list
  -- a group on its own opens what it's about (the Log tab, the map panel…), else lists its commands
  if b == "" then
    if e.run then return e.run("") end
    return M.groupHelp(e)
  end
  local w, rest = b:match("^(%S+)%s*(.-)$")
  local sub, maybe = pick(e.subs, w)
  if sub then return sub.run(rest) end
  if #maybe > 0 then return M.choose("sbo " .. e.name .. " " .. w, maybe, e.name .. " ") end
  -- no such sub-command: the group's own words (chat: a channel), or an old form (quest autopin on, map panel on)
  if e.rest then return e.rest(b) end
  if OLD[e.name] ~= nil then return M.oldCommand(e.name, args, b) end
  return M.groupHelp(e, "no '" .. w .. "' in sbo " .. e.name)
end

-- a short start fits several: say which, with links
function M.choose(typed, names, prefix)
  local out = {}
  for _, n in ipairs(names) do out[#out + 1] = "sbo " .. prefix .. n end
  say(typed .. " could be: " .. table.concat(out, " · ") .. " - type a little more")
end

-- a group renamed after 0.51 (gear -> eq, places -> map): still works, with a tip once
function M.renamed(old, new, r)
  if M.typing then
    M.oldTold = M.oldTold or {}
    if not M.oldTold[old] then M.oldTold[old] = true; say("tip: sbo " .. old .. " is sbo " .. new .. " now (the old name still works)") end
  end
  return M.command(new .. (r ~= "" and (" " .. r) or ""))
end

-- 0.51's sbo window tab / clear, and the older window on|off
function M.window051(r)
  local w, rest = r:match("^(%S*)%s*(.-)$")
  w = w:lower()
  if w == "on" or w == "off" then return M.oldCommand("window", "window " .. w, w) end
  local function tip(new)
    if M.typing then
      M.oldTold = M.oldTold or {}
      if not M.oldTold["window " .. w] then M.oldTold["window " .. w] = true; say("tip: that's sbo " .. new .. " now (the old form still works)") end
    end
  end
  if w == "tab" then tip("inspector / help / log / chat"); return M.windowTab(rest) end
  if w == "clear" then tip("inspector clear"); return legacy("clear") end
  for _, e in ipairs(M.CMDS) do if e.name == "window" then return M.groupHelp(e, "no '" .. w .. "' in sbo window") end end
end

-- sbo quest: the quest panel
function M.questShow()
  if M.cfg.questHud == false then return say("the quest panel is off: sbo config quest.hud on") end
  M.drawQuestTracker()
  if not next(M.cfg.questPins or {}) then say("no quests pinned: type quest info and click pin, or sbo quest pin {id|all}") end
end

-- sbo map: the map panel, on you
function M.mapPanelShow()
  if not M.cfg.map then return say("the map is off: sbo config map on") end
  if not M.cfg.mapPanel then return say("the map panel is off: sbo config map.panel on") end
  M.showMapPanel(true)
  if M.mapRoom then pcall(M.centerOn, M.mapRoom) end
end

-- the window tab by any start of its name
function M.windowTab(r)
  local tabs = { { name = "inspector" }, { name = "help" }, { name = "log" }, { name = "chat" }, { name = "notes" } }
  local t = pick(tabs, r)
  if not t then return say("sbo window tab inspector|help|log|chat") end
  return legacy("tab " .. t.name)
end

-- sbo debug state: busy flags and recent automatic decisions, shown and written to oven_state.txt
function M.debugState()
  local st = M.gmcpGet("char.status") or {}
  local lines = {
    "Oven v" .. M.version .. "  " .. os.date("%Y-%m-%d %H:%M:%S"),
    "room " .. tostring(M.mapRoom) .. " · last prompt " .. tostring(M.lastPromptText),
    "busy: " .. tostring(M.busyWhy(M.lastStatusPrompt or M.lastPromptText) or "no"),
    string.format("walk %s · running %s · cap %s · learning %s · learnQueue %s · quietNext %s",
      tostring(M.walk ~= nil), tostring(M.running and M.running.name), tostring(M.cap and M.cap.kind),
      tostring(M.learning ~= nil), tostring(M.learnQueue and #M.learnQueue), tostring(M.quietNext and M.quietNext.kind)),
    string.format("fighting %s (fights %d · status enemy %s, position %s, state %s, %ss ago)", tostring(M.fighting()),
      (function() local n = 0 for _ in pairs(M.fights or {}) do n = n + 1 end return n end)(), tostring(st.enemy),
      tostring(st.position), tostring(st.state), M.live.statusAt and tostring(os.time() - M.live.statusAt) or "never"),
    "shop list " .. tostring(M.cfg.shopList ~= false) .. " · this room a shop: " .. tostring(M.isShopRoom(M.mapRoom)),
    "", "recent automatic decisions:",
  }
  for _, n in ipairs(M.autoNotes or {}) do lines[#lines + 1] = "  " .. n end
  local f = io.open(getMudletHomeDir() .. "/oven_state.txt", "w")
  if f then f:write(table.concat(lines, "\n"), "\n"); f:close() end
  for _, l in ipairs(lines) do say(l) end
end

-- sbo stop: whatever Oven is doing for you
function M.stopAll()
  local what = {}
  if M.walk or (M.running and M.running.target) then
    M.walk = nil
    if M.running then M.running.target = nil end
    what[#what + 1] = "the walk"
  end
  if M.learnQueue or M.learnThen then
    M.learnQueue, M.learnDone, M.learnThen = nil, nil, nil
    what[#what + 1] = "looking at items"
  end
  if M.pickupPending then M.pickupPending = nil; what[#what + 1] = "looking at picked-up items" end
  if #what == 0 then return say("nothing to stop") end
  say("stopped " .. table.concat(what, " and ") .. (M.running and " (a signpost run goes on until it stops)" or ""))
end

-- sbo eq compare against [item]
function M.compareAgainst(item)
  item = trim(item or "")
  if item ~= "" then return legacy("pin " .. item) end
  local was = M.pinned and (M.pinned.name or M.pinned)
  M.pinned = nil; M.saveItems()
  say(was and ("no longer comparing against " .. tostring(was)) or "not comparing against anything (sbo eq compare against {item})")
end

-- sbo map highlight {what}: every room with it, lit up on the map (the best kind of match only: a tag or
-- NPC over a room name), centred on the latest sighting; no argument clears them
function M.mapHighlightAll(q, quiet)
  for _, id in ipairs(M.mapHighlights or {}) do pcall(unHighlightRoom, id) end
  M.mapHighlights = {}
  q = trim(q or "")
  M.mapHighlightQuery = (q ~= "") and q or nil   -- kept up to date as Oven learns more (M.mapLearned)
  if q == "" then return say("map highlights cleared") end
  -- "trainer in rune": only rooms in an area whose name has "rune" in it
  local what, area = q:match("^(.-)%s+in%s+(.+)$")
  what = what or q
  local okT, targets = pcall(M.runTargets, what)
  if not okT or type(targets) ~= "table" then targets = {} end
  if area then
    local kept = {}
    for _, t in ipairs(targets) do
      local a = getRoomArea(t.id)
      local an = a and getRoomAreaName(a) or ""
      if an:lower():find(area:lower(), 1, true) then kept[#kept + 1] = t end
    end
    targets = kept
  end
  if #targets == 0 then return quiet or say("no rooms Oven knows with '" .. q .. "'") end
  local best = math.huge
  for _, t in ipairs(targets) do best = math.min(best, t.rank or 9) end
  local lit = {}
  for _, t in ipairs(targets) do
    if (t.rank or 9) == best then
      pcall(highlightRoom, t.id, 255, 165, 0, 255, 215, 0, 1.2, 220, 80)
      M.mapHighlights[#M.mapHighlights + 1] = t.id
      lit[#lit + 1] = t.id
    end
  end
  -- where to centre: one NPC seen in several rooms (a traveling seller) - where it was seen last;
  -- several different matches (trainers…) - the nearest to you
  local keys = {}
  for _, r in ipairs(M.dbRows("SELECT DISTINCT key FROM room_npcs WHERE instr(lower(text), %s) > 0", what:lower())) do keys[#keys + 1] = r.key end
  local centre, note
  if #keys == 1 then
    local r = M.dbRow("SELECT room, last FROM room_npcs WHERE key = %s ORDER BY last DESC LIMIT 1", keys[1])
    if r then
      centre = tonumber(r.room)
      note = " · centred on the latest sighting, " .. M.shortDur(os.time() - (tonumber(r.last) or os.time())) .. " ago"
    end
  end
  if not centre then
    local here, nearest, steps = M.mapRoom, nil, nil
    for _, id in ipairs(lit) do
      local n
      if id == here then n = 0 elseif here and getPath(here, id) then n = #speedWalkDir end
      if n and (not steps or n < steps) then nearest, steps = id, n end
    end
    centre = nearest or lit[1]
    note = steps and string.format(" · centred on the nearest, %d step%s away", steps, steps == 1 and "" or "s") or ""
  end
  if quiet then return end
  if centre then
    if M.mapPanel and M.cfg.mapPanel then pcall(M.showMapPanel, true) end
    pcall(M.centerOn, centre)
  end
  say(string.format("%d room%s lit up on the map for '%s'%s  (sbo map highlight clears them)", #M.mapHighlights,
    #M.mapHighlights == 1 and "" or "s", q, note or ""))
end

-- something new about a room (an NPC or tag, a shop listed, a where-is feature, a bookmark): a highlight
-- that's showing is redone, quietly, so a new match lights up without moving the map
function M.mapLearned()
  if not M.mapHighlightQuery or M.mapRelightPending then return end
  M.mapRelightPending = true
  tempTimer(0.2, function()
    M.mapRelightPending = nil
    if M.mapHighlightQuery then pcall(M.mapHighlightAll, M.mapHighlightQuery, true) end
  end)
end

-- sbo map find: a room number centres the map; otherwise NPCs, tags and rooms, nearest first
function M.placesFind(q)
  q = trim(q or "")
  if q == "" then return say("sbo map find {what}: an NPC, a [tag], a room name, or a room #") end
  if tonumber(q) then return legacy("map show " .. q) end
  local okT, targets = pcall(M.runTargets, q)
  if M.cfg.map and M.mapRoom and okT and type(targets) == "table" and #targets > 0 then return M.mapRun("all " .. q) end
  return M.mapFind(q)
end

-- sbo log clear kills|loot: asks first (type it again within 30 seconds)
function M.logClear(r)
  local w = (r or ""):lower()
  local what = (w ~= "" and ("kills"):sub(1, #w) == w) and "kills" or ((w ~= "" and ("loot"):sub(1, #w) == w) and "loot" or nil)
  if not what then return say("sbo log clear kills · sbo log clear loot") end
  local p = M.pendingClear
  if p and p.what == what and os.time() - p.at <= 30 then
    M.pendingClear = nil
    return legacy(what .. " clear")
  end
  local n = M.dbRow("SELECT COUNT(*) AS n FROM " .. what)
  M.pendingClear = { what = what, at = os.time() }
  say(string.format("this wipes all %s %s ever logged - type sbo log clear %s again within 30 seconds to do it",
    tostring(n and n.n or 0), what == "kills" and "kill rows" or "loot rows", what))
end

-- sbo version
function M.versionInfo()
  local st = M.updState or {}
  local extra = ""
  if st.state == "avail" and st.ver then extra = " · v" .. st.ver .. " is available: sbo version update" end
  say(string.format("Soft Bun's Oven v%s · automatic updates %s%s", M.version, M.cfg.autoUpdate and "on" or "off", extra))
end

---------------------------------------------------------------------------
-- sbo config: every setting in one place
---------------------------------------------------------------------------
local function onoff(v) return v and "on" or "off" end
local BOOL = { "on", "off" }
-- { key, group, values (list, or "number", "rgb", "text"), get(), set(v) }
M.SETTINGS = {
  { "formatting", "Display", BOOL, function() return onoff(M.cfg.enabled) end, function(v) legacy(v) end },
  { "main", "Display", { "replace", "keep" }, function() return M.cfg.main end, function(v) legacy("main " .. v) end },
  { "window", "Display", BOOL, function() return onoff(M.cfg.window) end, function(v) legacy("window " .. v) end },
  { "help.window", "Help tab", BOOL, function() return onoff(M.cfg.helpWindow) end, function(v) legacy("helpwindow " .. v) end },
  { "tabs", "Display", BOOL, function() return onoff(M.cfg.tabs) end, function(v) legacy("tabs " .. v) end },
  { "tabs.auto", "Display", BOOL, function() return onoff(M.cfg.tabAuto ~= false) end, function(v) legacy("tabs auto " .. v) end },
  { "inspector.mirror", "Inspector tab", BOOL, function() return onoff((M.cfg.mirror or {}).view) end, function(v) legacy("mirror inspector " .. v) end },
  { "help.mirror", "Help tab", BOOL, function() return onoff((M.cfg.mirror or {}).help) end, function(v) legacy("mirror help " .. v) end },
  { "log.mirror", "Log tab", BOOL, function() return onoff((M.cfg.mirror or {}).log) end, function(v) legacy("mirror log " .. v) end },
  { "chat.mirror", "Chat tab", BOOL, function() return onoff((M.cfg.mirror or {}).chat) end, function(v) legacy("mirror chat " .. v) end },
  { "font", "Display", "number", function() return tostring(M.cfg.fontSize or "") end, function(v) legacy("font " .. v) end },
  { "eq.autocompare", "Equipment", BOOL, function() return onoff(M.cfg.autocompare) end, function(v) legacy("autocompare " .. v) end },
  { "eq.pickuplook", "Equipment", BOOL, function() return onoff(M.cfg.pickupLook) end, function(v) legacy("pickup look " .. v) end },
  { "eq.stats", "Equipment", BOOL, function() return onoff(M.cfg.eqStats) end, function(v) legacy("eqstats " .. v) end },
  { "eq.empty", "Equipment", BOOL, function() return onoff(M.cfg.showEmpty) end, function(v) legacy("empty " .. v) end },
  { "eq.donation", "Equipment", BOOL, function() return onoff(M.cfg.showDonation) end, function(v) legacy("donation " .. v) end },
  { "eq.slots", "Equipment", { "short", "full" }, function() return M.cfg.slotNames or "short" end, function(v) legacy("slots " .. v) end },
  { "eq.gamecolors", "Equipment", BOOL, function() return onoff(M.cfg.gameColors) end, function(v) legacy("gamecolors " .. v) end },
  { "quest.hud", "Quest panel", BOOL, function() return onoff(M.cfg.questHud ~= false) end,
    function(v) M.cfg.questHud = (v == "on"); M.saveSettings(); M.drawQuestTracker(); say("quest HUD " .. v) end },
  { "quest.autopin", "Quest panel", BOOL, function() return onoff(M.cfg.questAutoPin ~= false) end, function(v) legacy("quest autopin " .. v) end },
  { "quest.blurb", "Quest panel", BOOL, function() return onoff(M.cfg.questHudBlurb) end, function(v) legacy("quest hud blurb " .. v) end },
  { "quest.side", "Quest panel", { "left", "right" }, function() return M.cfg.questHudSide or "right" end, function(v) legacy("quest hud " .. v) end },
  { "quest.opacity", "Quest panel", "number", function() return tostring(M.cfg.questHudOpacity or 100) end, function(v) legacy("quest hud opacity " .. v) end },
  { "map", "Map panel", BOOL, function() return onoff(M.cfg.map) end, function(v) legacy("map " .. v) end },
  { "map.panel", "Map panel", BOOL, function() return onoff(M.cfg.mapPanel) end, function(v) legacy("map panel " .. v) end },
  { "map.card", "Map panel", BOOL, function() return onoff(M.cfg.mapCard) end, function(v) legacy("map card " .. v) end },
  { "map.wherelearn", "Map panel", BOOL, function() return onoff(M.cfg.whereLearn ~= false) end,
    function(v) M.cfg.whereLearn = (v == "on"); M.saveSettings(); say("learning each area's 'where is' features while you're idle: " .. v) end },
  { "map.shoplist", "Map panel", BOOL, function() return onoff(M.cfg.shopList ~= false) end,
    function(v) M.cfg.shopList = (v == "on"); M.saveSettings(); say("listing shops when you stop in one: " .. v) end },
  { "signposts.look", "Map panel", BOOL, function() return onoff(M.cfg.signLook) end, function(v) legacy("signposts look " .. v) end },
  { "bar", "Prompt bar", BOOL, function() return onoff(M.cfg.bar) end, function(v) legacy("bar " .. v) end },
  { "bar.mode", "Prompt bar", { "gauges", "raw" }, function() return M.cfg.barMode or "gauges" end, function(v) legacy("bar " .. v) end },
  { "bar.session", "Prompt bar", BOOL, function() return onoff(M.cfg.barSession) end, function(v) legacy("bar session " .. v) end },
  { "bar.session.style", "Prompt bar", { "full", "short" }, function() return M.cfg.barSessionStyle or "full" end, function(v) legacy("bar session " .. v) end },
  { "bar.session.place", "Prompt bar", { "top", "bottom" }, function() return M.cfg.barSessionPos or "top" end, function(v) legacy("bar session " .. v) end },
  { "bar.width", "Prompt bar", "number", function() return tostring(M.cfg.barWidth or "") end, function(v) legacy("bar width " .. v) end },
  { "bar.lines", "Prompt bar", "number", function() return tostring(M.cfg.barLines or "") end, function(v) legacy("bar lines " .. v) end },
  { "bar.font", "Prompt bar", "number", function() return tostring(M.cfg.barFont or "") end, function(v) legacy("bar font " .. v) end },
  { "bar.bg", "Prompt bar", "rgb", function() local c = M.cfg.barBg or {} return table.concat({ tostring(c[1]), tostring(c[2]), tostring(c[3]) }, " ") end,
    function(v) legacy("bar bg " .. v) end },
  { "bar.blanks", "Prompt bar", BOOL, function() return onoff(not M.cfg.barBlank) end, function(v) legacy("bar blanks " .. v) end },
  { "combat", "Combat bar", BOOL, function() return onoff(M.cfg.combatBar or M.cfg.combatLines) end, function(v) legacy("combat " .. v) end },
  { "combat.bar", "Combat bar", BOOL, function() return onoff(M.cfg.combatBar) end, function(v) legacy("combat bar " .. v) end },
  { "combat.lines", "Combat bar", BOOL, function() return onoff(M.cfg.combatLines) end, function(v) legacy("combat lines " .. v) end },
  { "update.auto", "Updates and debug", BOOL, function() return onoff(M.cfg.autoUpdate) end, function(v) M.update("auto " .. v) end },
  { "record.window", "Updates and debug", "number", function() return tostring(M.cfg.recWindow or "") end, function(v) legacy("record window " .. v) end },
  { "prompt", "Updates and debug", "text", function() return M.cfg.promptPattern ~= "" and M.cfg.promptPattern or "(automatic)" end,
    function(v) legacy("prompt " .. v) end },
}

-- the names settings had in 0.51
M.SETTING_RENAMED = { ["mirror.inspector"] = "inspector.mirror", ["mirror.help"] = "help.mirror", ["mirror.log"] = "log.mirror",
  ["mirror.chat"] = "chat.mirror", ["gear.autocompare"] = "eq.autocompare", ["gear.pickuplook"] = "eq.pickuplook" }
M.SETTING_GROUPS = { "Display", "Inspector tab", "Help tab", "Log tab", "Chat tab", "Quest panel", "Map panel",
  "Prompt bar", "Combat bar", "Equipment", "Updates and debug" }

-- a setting by its name or any start of each part: "bar.w" = bar.width, "q.op" = quest.opacity
function M.settingFind(q)
  q = (q or ""):lower()
  q = M.SETTING_RENAMED[q] or q
  for _, s in ipairs(M.SETTINGS) do if s[1] == q then return s end end
  local qp = {}
  for x in q:gmatch("[^%.]+") do qp[#qp + 1] = x end
  local hits = {}
  for _, s in ipairs(M.SETTINGS) do
    local sp = {}
    for x in s[1]:gmatch("[^%.]+") do sp[#sp + 1] = x end
    if #sp == #qp then
      local ok = true
      for i = 1, #qp do if sp[i]:sub(1, #qp[i]) ~= qp[i] then ok = false; break end end
      if ok then hits[#hits + 1] = s end
    end
  end
  if #hits == 1 then return hits[1] end
  return nil, hits
end

local function valuesText(s)
  if type(s[3]) == "table" then return table.concat(s[3], "|") end
  return ({ number = "{n}", rgb = "{r g b}", text = "{pattern}" })[s[3]] or ""
end

function M.config(r)
  r = trim(r or "")
  if r == "" then return M.configList() end
  local name, v = r:match("^(%S+)%s*(.-)$")
  local s, hits = M.settingFind(name)
  if not s then
    if hits and #hits > 1 then
      local n = {}
      for _, h in ipairs(hits) do n[#n + 1] = h[1] end
      return say(name .. " could be: " .. table.concat(n, " · ") .. " - type a little more")
    end
    -- a group's start ("sbo config bar"): just those
    return M.configList(name)
  end
  if v == "" then
    return say(string.format("%s is %s  (sbo config %s %s)", s[1], s[4](), s[1], valuesText(s)))
  end
  if type(s[3]) == "table" then
    local val = pick((function() local l = {} for _, x in ipairs(s[3]) do l[#l + 1] = { name = x } end return l end)(), v)
    if not val then return say(s[1] .. " takes " .. valuesText(s)) end
    v = val.name
  elseif s[3] == "number" and not tonumber(v) and v ~= "default" then
    return say(s[1] .. " takes a number (or default)")
  end
  if v == "default" then v = "" end
  s[5](v)
  M.saveSettings()
end

function M.configList(only)
  only = only and only:lower() or nil
  local width = M.cfg.window and M.viewCols() or columns("main")
  local out, links = { header("help", "", width, "Settings  (sbo config {name} {value})") }, {}
  local last
  local kw = 0
  for _, s in ipairs(M.SETTINGS) do kw = math.max(kw, ulen(s[1])) end
  local shown = 0
  local ordered = {}
  for _, g in ipairs(M.SETTING_GROUPS) do
    for _, x in ipairs(M.SETTINGS) do if x[2] == g then ordered[#ordered + 1] = x end end
  end
  for _, s in ipairs(ordered) do
    if not only or s[1]:sub(1, #only) == only or s[2]:lower():sub(1, #only) == only then
      shown = shown + 1
      if s[2] ~= last then
        if last then out[#out + 1] = {} end
        out[#out + 1] = { { M.REC or C.title, "▸ " .. s[2] } }
        last = s[2]
      end
      local cur = s[4]()
      out[#out + 1] = { { C.key, "  " .. pad(s[1], kw + 2) }, { (cur == "on") and C.plus or ((cur == "off") and C.dim or C.num), pad(cur, 10) },
                        { C.dim, valuesText(s) } }
      if s[3] == BOOL then
        local key = s[1]
        links[#links + 1] = { key .. " → " .. (cur == "on" and "off" or "on"), function()
          M.config(key .. " " .. (s[4]() == "on" and "off" or "on")); M.configList(only) end }
      end
    end
  end
  if shown == 0 then return say("no setting called '" .. only .. "' - sbo config lists them all") end
  M.viewOut(out, links)
end

---------------------------------------------------------------------------
-- sbo (the menu), sbo {group} and sbo help
---------------------------------------------------------------------------
-- "gear" with its shortest start bright: <khaki>ge<dim>ar
local function marked(list, e)
  local n = shortest(list, e)
  return "<khaki>" .. e.name:sub(1, n) .. "<light_slate_grey>" .. e.name:sub(n + 1) .. "<reset>"
end
local function argsText(a)
  if not a or a == "" then return "" end
  return " <light_slate_grey>" .. a:gsub("[{}]", "") .. "<reset>"
end

local function helpOut(title, lines)
  local text = table.concat(lines, "\n")
  if M.cfg.helpWindow then
    M.helpPage(title, lines, "cecho")
  else
    M.log(text)
  end
end

function M.menu()
  local lines = { "", "<orange>Soft Bun's Oven<reset> <dim_grey>v" .. M.version .. "  ·  `oven` works as well as `sbo`<reset>", "" }
  local w = 0
  local function shownOf(e) return e.name .. ((not e.subs and e.args) and (" " .. e.args:gsub("[{}]", "")) or "") end
  for _, e in ipairs(M.CMDS) do if not e.alias and not e.shortcut then w = math.max(w, ulen(shownOf(e))) end end
  for _, e in ipairs(M.CMDS) do
    if not e.alias and not e.shortcut then
      local shown = shownOf(e)
      lines[#lines + 1] = "  sbo " .. marked(M.CMDS, e) .. (e.subs and "" or argsText(e.args))
        .. string.rep(" ", w - ulen(shown) + 3) .. "<dim_grey>" .. (e.desc or "") .. "<reset>"
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<dim_grey>sbo help {group}: its commands  ·  sbo help all: everything  ·  shortcuts: sbo compare, sbo upgrades<reset>"
  lines[#lines + 1] = "<dim_grey>any start of a word works: the bright part is enough (sbo e up = sbo eq upgrades)<reset>"
  helpOut("Soft Bun's Oven", lines)
end

local function groupLines(e, lines)
  lines[#lines + 1] = "<turquoise>▸ sbo " .. e.name .. "<reset>  <dim_grey>" .. (e.desc or "") .. "<reset>"
  if e.run then
    lines[#lines + 1] = "  sbo " .. marked(M.CMDS, e) .. argsText(e.args) .. "   <dim_grey>on its own: "
      .. ((e.desc or ""):match("^(the [%a ]-):") or "this") .. "<reset>"
  end
  local w = 0
  for _, s in ipairs(e.subs) do w = math.max(w, ulen(s.name .. (s.args and (" " .. s.args:gsub("[{}]", "")) or ""))) end
  for _, s in ipairs(e.subs) do
    local shown = s.name .. (s.args and (" " .. s.args:gsub("[{}]", "")) or "")
    local nm = s.listOnly and ("<khaki>" .. s.name .. "<reset>") or marked(e.subs, s)
    lines[#lines + 1] = "  sbo " .. e.name .. " " .. nm .. argsText(s.args) .. string.rep(" ", w - ulen(shown) + 3)
      .. "<dim_grey>" .. (s.desc or "") .. "<reset>"
  end
end

function M.groupHelp(e, note)
  local lines = { "" }
  if note then lines[#lines + 1] = "<dim_grey>" .. note .. "<reset>"; lines[#lines + 1] = "" end
  groupLines(e, lines)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "<dim_grey>grey words: fill in your own  ·  [brackets]: optional  ·  a|b: one of them  ·  the bright part is enough<reset>"
  helpOut("sbo " .. e.name, lines)
end

function M.help(section)
  section = trim(section or ""):lower()
  if section == "" then return M.menu() end
  if section == "all" then
    local lines = { "" }
    for _, e in ipairs(M.CMDS) do
      if e.subs then groupLines(e, lines); lines[#lines + 1] = ""
      elseif not e.alias and not e.shortcut then
        lines[#lines + 1] = "<turquoise>▸ sbo " .. e.name .. "<reset>" .. argsText(e.args) .. "  <dim_grey>" .. (e.desc or "") .. "<reset>"
        lines[#lines + 1] = ""
      end
    end
    return helpOut("Soft Bun's Oven: every command", lines)
  end
  if section == "config" or section == "settings" then return M.configList() end
  local e = pick(M.CMDS, section)
  if e and e.alias then e = pick(M.CMDS, (e.alias:match("^(%S+)"))) end
  if e and e.subs then return M.groupHelp(e) end
  if e then return M.menu() end
  return M.menu()
end

-- Updates come from GitHub: VERSION says what's current, Oven.mpackage is the package.
M.REPO = "@@REPO@@"
M.BRANCH = "main"
-- Files are fetched from the exact latest commit (raw.githubusercontent.com/<repo>/<sha>/...):
-- the branch address is cached by GitHub for up to 5 minutes, a commit address is always
-- current. The latest commit comes from git's own ref list (what `git pull` reads), which
-- is never cached - the REST API can lag a minute behind a push. If that fails, the branch
-- address is used instead.
function M.rawUrl(file)
  return "https://raw.githubusercontent.com/" .. M.REPO .. "/" .. (M.updSha or M.BRANCH) .. "/" .. file
end
function M.apiUrl() return "https://github.com/" .. M.REPO .. ".git/info/refs?service=git-upload-pack" end

-- step 1 of every check: find the latest commit, then fetch VERSION from it
function M.fetchVersion()
  M.updSha = nil
  downloadFile(M.dl.api, M.apiUrl())
end
M.dl = { version = getMudletHomeDir() .. "/oven_latest_version.txt", pkg = getMudletHomeDir() .. "/oven_latest.mpackage",
         api = getMudletHomeDir() .. "/oven_latest_refs.txt" }

local function newer(a, b)  -- is version a newer than b?
  local function parts(v) local t = {} for n in tostring(v):gmatch("%d+") do t[#t + 1] = tonumber(n) end return t end
  local x, y = parts(a), parts(b)
  for i = 1, math.max(#x, #y) do
    if (x[i] or 0) ~= (y[i] or 0) then return (x[i] or 0) > (y[i] or 0) end
  end
  return false
end
M.newer = newer

-- update messages: a short note on the prompt bar when it's on, otherwise a line in the log
-- an update message -> state for the bar's version tag, and a log line (nil = not worth one)
-- states: check, down (downloading/installing), ok (up to date), avail (newer exists), err
function M.compactStatus(msg)
  msg = msg:gsub("<[%w_]+>", "")
  local v
  if msg:find("^checking") then return "check", nil end
  v = msg:match("^downloading v(%S-)…?$") or msg:match("^new version v(%S+) %-")
  if v then return "down", nil, v end
  if msg:find("^installing") then return "down", nil, M.updState and M.updState.ver end
  v = msg:match("^updated: v%S+ %-> v(%S+)")
  if v then return "ok", "✓ updated to v" .. v end
  v = msg:match("latest version %(v(%S+)%)")
  if v then return "ok", "✓ up to date (v" .. v .. ")" end
  v = msg:match("^v(%S+) is available")
  if v then return "avail", "↑ v" .. v .. " available - sbo version update", v end
  if msg:find("fail") then return "err", "✗ " .. msg end
  return nil, msg
end

-- update status: the bar's version tag when the bar is on; otherwise one log line for outcomes
function M.notify(msg, secs)
  local state, long, ver = M.compactStatus(msg)
  if state then M.updState = { state = state, ver = ver } end
  if M.cfg.bar and M.bar and M.bar.rawEcho then
    pcall(M.drawBar)
  elseif long then
    M.log("<dim_grey>[sbo] " .. long .. "<reset>")
  end
end

-- a click on the bar: on the version tag (right end) = sbo version update
function M.barClick(ev)
  if type(ev) ~= "table" or not ev.x or not M.bar then return end
  local font = (pcall(getFont) and getFont()) or "monospace"
  local ok, cw = pcall(calcFontSize, M.barFontSize(), font)
  cw = (ok and tonumber(cw)) or 8
  local tagW = (ulen(" [v" .. M.version .. " ✓]") + 2) * cw + 6
  local w = M.bar:get_width()
  if ev.x < w - tagW then return end
  local st = (M.updState or {}).state
  if st == "check" or st == "down" or M.updating then return say("already checking for an update…") end
  M.update()
end

-- "v0.11.9 ✓" at the end of the bar: ✓ current, ↑ update available, ⟳ checking, ⇣ updating, ✗ error
function M.versionTag()
  local st = M.updState or {}
  local segs = { { C.dim, "[v" .. M.version } }
  if st.state == "ok" then segs[#segs + 1] = { C.plus, " ✓" }
  elseif st.state == "avail" and st.ver and M.newer(st.ver, M.version) then segs[#segs + 1] = { C.flag, " ↑" }
  elseif st.state == "check" then segs[#segs + 1] = { C.dim, " ⟳" }
  elseif st.state == "down" then segs[#segs + 1] = { C.slot, " ⇣" }
  elseif st.state == "err" then segs[#segs + 1] = { C.minus, " ✗" } end
  segs[#segs + 1] = { C.dim, "]" }
  return segs
end

function M.installFrom(path)
  if M.cap then   -- don't reinstall in the middle of capturing something
    return tempTimer(2, function() M.installFrom(path) end)
  end
  M.notify(path:find("oven_latest", 1, true) and "installing update…" or ("installing " .. path))
  local old = M.version
  M.updating = true   -- keep the windows and bar up while the package is swapped
  for _, pkg in ipairs({ "MMFormat", "SoftbunsOS", "Oven" }) do  -- old names too
    if table.contains(getPackages(), pkg) then uninstallPackage(pkg) end
  end
  tempTimer(1, function()
    installPackage(path)
    tempTimer(1, function()
      if sbo and sbo.version then
        local msg = "updated: v" .. old .. " -> v" .. sbo.version
        if sbo.notify then sbo.notify(msg, 10)
        elseif sbo and sbo.log then sbo.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> " .. msg)
        else cecho("\n<dim_grey>[<orange>sbo<dim_grey>]<reset> " .. msg .. "\n") end
      end
    end)
  end)
end

-- mode: "check" (quiet, just tell me), "update", "force"
function M.update(arg)
  arg = trim(arg or "")
  local auto = arg:match("^auto%s*(%a*)$")
  if auto then
    if auto == "on" or auto == "off" then
      M.cfg.autoUpdate = (auto == "on"); M.saveSettings(); M.startUpdatePoll()
    end
    return say("automatic updates " .. (M.cfg.autoUpdate and "on: new versions install themselves within a few minutes"
      or "off: you're told when a new version is out (sbo config update.auto on to install them automatically)"))
  end
  if arg ~= "" and arg ~= "force" then
    -- a local .mpackage file, for testing your own builds
    if not io.exists(arg) then return say("package file not found: " .. arg) end
    return M.installFrom(arg)
  end
  if M.REPO:find("@@", 1, true) then return say("no GitHub repository configured in this build") end
  M.pending = (arg == "force") and "force" or "update"
  M.notify("checking for updates…")
  M.fetchVersion()
end

function M.checkForUpdate()
  if M.REPO:find("@@", 1, true) or not M.cfg.updateCheck or M.pending then return end
  M.pending = M.cfg.autoUpdate and "auto" or "check"
  if M.cfg.bar then M.updState = { state = "check" }; pcall(M.drawBar) end
  M.fetchVersion()
end

-- with automatic updates on, look for a new version every couple of minutes
function M.startUpdatePoll()
  if M.pollTimer then killTimer(M.pollTimer); M.pollTimer = nil end
  if M.cfg.autoUpdate and not M.REPO:find("@@", 1, true) then
    M.pollTimer = tempTimer(120, function() M.checkForUpdate() end, true)
  end
end

function M.onDownload(event, file, err)
  if file ~= M.dl.version and file ~= M.dl.pkg and file ~= M.dl.api then return end
  local mode = M.pending
  if not mode then return end  -- nothing of ours in flight
  if file == M.dl.api then
    -- latest commit id; on any problem fall back to the branch address
    if event ~= "sysDownloadError" then
      local f = io.open(file, "rb"); local body = f and f:read("*a") or ""; if f then f:close() end
      -- pkt-line: "<4 hex length><40 hex sha> refs/heads/main"
      local hex = body:match("(%x+) refs/heads/" .. M.BRANCH .. "%f[%z%s]") or body:match("(%x+) refs/heads/" .. M.BRANCH .. "$")
      M.updSha = (hex and #hex >= 40) and hex:sub(-40) or nil
    end
    downloadFile(M.dl.version, M.rawUrl("VERSION"))
    return
  end
  if event == "sysDownloadError" then
    M.pending = nil
    if mode ~= "check" and mode ~= "auto" then M.notify("update download failed: " .. tostring(err or file))
    else M.updState = { state = "err" }; pcall(M.drawBar) end
    return
  end
  if file == M.dl.version then
    local f = io.open(file); local latest = f and trim(f:read("*a") or ""); if f then f:close() end
    if not latest or latest == "" then M.pending = nil; return end
    if mode == "check" then
      M.pending = nil
      if not newer(latest, M.version) then M.updState = { state = "ok" }; pcall(M.drawBar) end
      if newer(latest, M.version) and latest ~= M.toldAbout then
        M.toldAbout = latest
        M.notify("v" .. latest .. " is available (you have v" .. M.version .. ") - type sbo version update")
      end
    elseif mode == "auto" and not newer(latest, M.version) then
      M.pending = nil
      M.updState = { state = "ok" }; pcall(M.drawBar)
    elseif newer(latest, M.version) or mode == "force" then
      M.notify(mode == "auto" and ("new version v" .. latest .. " - updating automatically…") or ("downloading v" .. latest .. "…"))
      downloadFile(M.dl.pkg, M.rawUrl("Oven.mpackage"))
    else
      M.pending = nil
      M.notify("you already have the latest version (v" .. M.version .. ")")
    end
  elseif file == M.dl.pkg then
    M.pending = nil
    M.installFrom(file)
  end
end

---------------------------------------------------------------------------
-- Setup (safe to re-run)
---------------------------------------------------------------------------
---------------------------------------------------------------------------
-- Panel layout: where you put the Inspector, Help and Map windows is saved (a few seconds after you
-- move or resize one) and put back after every connect, once other UI packages have settled.
-- Mudlet itself only saves them when you exit, and other packages may rearrange things on connect.
---------------------------------------------------------------------------
M.PANEL_DEFAULTS = {
  ovenViewer   = { x = "-62%", y = "4%", w = "36%", h = "50%" },
  ovenHelp     = { x = "2%", y = "4%", w = "45%", h = "70%" },
  ovenMapPanel = { x = "-36%", y = "4%", w = "34%", h = "50%" },
}
function M.panelList()
  return { { "ovenViewer", M.container }, { "ovenHelp", M.helpContainer }, { "ovenMapPanel", M.mapPanel } }
end

local function panelGeom(c)
  local ok, x, y, w, h = pcall(function() return c:get_x(), c:get_y(), c:get_width(), c:get_height() end)
  if ok and tonumber(x) and tonumber(w) then return { x, y, w, h } end
end

-- as fractions of the main window, so a different window size keeps the arrangement
function M.panelsSave(force)
  -- just connected: what's on screen may be another package's doing - wait until ours are put back
  if M.panelsHold and not force then return end
  local W, H = getMainWindowSize()
  if not W or W == 0 then return end
  M.cfg.panels = M.cfg.panels or {}
  local changed = false
  for _, p in ipairs(M.panelList()) do
    local name, c = p[1], p[2]
    local g = c and not c.attached and panelGeom(c)
    if g then
      local f = { x = g[1] / W, y = g[2] / H, w = g[3] / W, h = g[4] / H }
      local old = M.cfg.panels[name]
      local function near(a, b) return a and b and math.abs(a - b) < 0.002 end
      if force or not (old and near(old.x, f.x) and near(old.y, f.y) and near(old.w, f.w) and near(old.h, f.h)) then
        M.cfg.panels[name] = f
        pcall(function() c:save() end)   -- Mudlet's own copy too
        changed = true
      end
    end
  end
  if changed then M.saveSettings() end
  return changed
end

local function pct(f) return string.format("%.3f%%", f * 100) end
function M.panelPlace(name, c)
  local f = (M.cfg.panels or {})[name]
  if not c or not f or c.attached then return end
  pcall(function() c:move(pct(f.x), pct(f.y)); c:resize(pct(f.w), pct(f.h)) end)
end
function M.panelsRestore()
  for _, p in ipairs(M.panelList()) do M.panelPlace(p[1], p[2]) end
end

function M.panelsReset()
  M.cfg.panels = nil
  M.saveSettings()
  for _, p in ipairs(M.panelList()) do
    local d, c = M.PANEL_DEFAULTS[p[1]], p[2]
    if c and d then pcall(function() c:move(d.x, d.y); c:resize(d.w, d.h); c:save() end) end
  end
end

-- look every few seconds; save once a panel has stopped moving
function M.panelsWatch()
  if M.panelTimer then killTimer(M.panelTimer) end
  M.panelTimer = tempTimer(4, function() pcall(M.panelsSave) end, true)   -- repeating
end

-- quest time limits count down on the quest panel and the bar
function M.questClock()
  if M.questClockTimer then killTimer(M.questClockTimer) end
  M.questClockTimer = tempTimer(30, function()
    local any = false
    for _, Q in pairs(M.quests or {}) do if Q.active ~= false and Q.deadline then any = true; break end end
    if not any then return end
    if next(M.cfg.questPins or {}) then pcall(M.drawQuestTracker) end
    pcall(M.drawBar)
  end, true)   -- repeating
end

function M.teardown()
  if M.panelTimer then killTimer(M.panelTimer); M.panelTimer = nil end
  if M.questClockTimer then killTimer(M.questClockTimer); M.questClockTimer = nil end
  if M.whereTimer then killTimer(M.whereTimer); M.whereTimer = nil end
  pcall(M.panelsSave)
  pcall(M.dbClose)
  if M.handlers then for _, h in ipairs(M.handlers) do killAnonymousEventHandler(h) end end
  if M.lineTrigger then killTrigger(M.lineTrigger) end
  if M.alias then killAlias(M.alias) end
  M.handlers, M.lineTrigger, M.alias = nil, nil, nil
  if M.pollTimer then killTimer(M.pollTimer); M.pollTimer = nil end
  if M.sessTimer then killTimer(M.sessTimer); M.sessTimer = nil end
  if M.mapHandler then killAnonymousEventHandler(M.mapHandler); M.mapHandler = nil end
  if M.mapHoverTimer then killTimer(M.mapHoverTimer); M.mapHoverTimer = nil end   -- (0.16.4's hover)
  if M.mapHoverTip then pcall(function() M.mapHoverTip:hide() end) end
  if M.mapSelTimer then killTimer(M.mapSelTimer); M.mapSelTimer = nil end
  pcall(M.gmcpUnwatch)
end

function M.init()
  M.updating = nil
  M.teardown()
  M.dropPages()
  M.loadSettings()
  if not M.dbOpen() then
    M.log("<red>[sbo] couldn't open the database (oven.db) - items, loot and kills won't be saved this session<reset>")
  end
  local okI, errI = pcall(M.importOld)
  if not okI then M.log("<red>[sbo] moving your saved data into the database failed: " .. tostring(errI) .. "<reset>") end
  pcall(M.rotateSamples)
  -- 0.20.5 and older saved help-page tag legends ("[Guide] - The character is...") as NPCs
  pcall(M.dbx, "DELETE FROM room_npcs WHERE substr(text, 1, 1) NOT GLOB '[A-Za-z0-9\"'']'")
  M.quests = M.cfg.quests or M.quests or {}
  pcall(M.fixQuestPhases)
  M.handlers = {
    registerAnonymousEventHandler("sysDataSendRequest", M.onSend),
    registerAnonymousEventHandler("sysExitEvent", function() pcall(M.dbClose) end),
    registerAnonymousEventHandler("sysUninstallPackage", function(_, pkg)
      if pkg == "Oven" then
        M.teardown()
        if M.updating then return end   -- an update: the new version takes the windows over
        if M.container then M.container:hide() end
        if M.helpContainer then M.helpContainer:hide() end
        if M.questContainer then M.questContainer:hide() end
        if M.questHud then M.questHud:hide() end
        for _, c in ipairs(M.questCards or {}) do c:hide() end
        if M.mapPanel then M.mapPanel:hide() end
        if M.bar then M.bar:hide(); setBorderBottom(0) end
        if M.sbar then M.sbar:hide() end
        if M.topTaken then setBorderTop(M.baseTop or 0); M.topTaken = nil end
      end
    end),
  }
  for _, h in ipairs(M.gmcpHandlersList()) do M.handlers[#M.handlers + 1] = h end
  M.loadItems()
  M.gmcpCatchUp()
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysWindowResizeEvent", function() M.layoutBar(); pcall(M.drawBar); pcall(M.layoutQuestHud) end)
  -- after a connect, once other UI packages have rearranged things: your panels back where you had them
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysConnectionEvent", function()
    M.panelsHold = true
    tempTimer(3, function() pcall(M.panelsRestore); M.panelsHold = nil end)
  end)
  M.panelsWatch()
  M.questClock()
  M.whereLearnStart()
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysDownloadDone", M.onDownload)
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysDownloadError", M.onDownload)
  for _, v in ipairs({ "LEVEL", "EXPERIENCE", "EXPERIENCE_MAX", "EXPERIENCE_TNL", "EXPERIENCE_TO_LEVEL" }) do
    M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("msdp." .. v, M.onMsdp)
  end
  M.lineTrigger = tempRegexTrigger("^", function() M.onLine() end)
  M.alias = tempAlias("^(?:sbo|oven)(?:\\s+(.*))?$", function() M.typedCommand(matches[2]) end)
  if M.cfg.window and M.container then
    M.container:show()
    -- an update in the middle of a session: rebuild the open window with (or without) its tabs
    pcall(M.viewShow)
  end
  if M.cfg.bar then M.showBar(true) end
  if M.cfg.map then M.mapStart() end
  if M.cfg.mapPanel then pcall(M.showMapPanel, true) end
  if next(M.cfg.questPins or {}) then pcall(M.drawQuestTracker) end
  M.startUpdatePoll()
  if not M.booted then
    M.booted = true
    tempTimer(8, function() M.checkForUpdate() end)
    M.log("<dim_grey>[<orange>Soft Bun's Oven<dim_grey>] v" .. M.version ..
      " by softbuns :: preheated :: raw stream in, baked output out :: type <khaki>sbo<dim_grey> for commands<reset>")
  end
end

M.init()
