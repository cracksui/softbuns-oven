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

M.version = "0.11.13"
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
  fontSize     = 10,
  -- Lua pattern for your prompt, used in addition to telnet GA/EOR detection.
  -- Default: a line that is just <...> containing a digit, e.g. "<120hp 80sp 90st>".
  promptPattern = "^%s*<[^>]*%d[^>]*>%s*$",
  updateCheck  = true,       -- on login, quietly check GitHub for a newer version
  autoUpdate   = false,      -- check every 2 minutes and install new versions automatically
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
  M.cfg = t
end
function M.saveSettings() table.save(M.settingsFile, M.cfg) end

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
  { word = "practice",  min = 3, kind = "skills" },
  { word = "train",     min = 3, kind = "skills" },
}

function M.classify(cmd)
  local c = cmd:lower():gsub("^%s+", ""):gsub("%s+$", "")
  local verb, rest = c:match("^(%S+)%s*(.-)$")
  if not verb or verb == "" then return nil end
  if verb == "?" then return "help", rest end
  for _, def in ipairs(M.commands) do
    if #verb >= def.min and def.word:sub(1, #verb) == verb and not (def.except and def.except[verb]) then
      if def.needsArgs and rest == "" then return nil end
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
        addAll(out, wrapWords(l, width, 2, C.text))
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
    else for _, l in ipairs(cur) do prose(out, { l }, width) end end
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
    if slot then slots[#slots + 1] = { slot, item, runs = M.runsFor(idx, (stripConds(item))) }; seenSlot = true
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
  for _, key in ipairs({ "viewPg", "helpPg" }) do
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
  end
  if M.console then M.console:hide() end   -- console used by versions before 0.10
  if not M.viewPg then M.viewPg = M.newPage("ovenView", M.container) end
  M.viewPg.container = M.container
end

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
  M.pageShow(M.viewPg, segsToDecho(e.lines), "decho", links)
end

---------------------------------------------------------------------------
-- Help window: game help pages exactly as sent (colours and layout kept)
---------------------------------------------------------------------------
function M.createHelpWindow()
  if not M.helpContainer then
    M.helpContainer = Adjustable.Container:new({
      name = "ovenHelp",
      titleText = "help",
      x = "2%", y = "4%", width = "45%", height = "70%",
      adjLabelstyle = "background-color: rgba(20,20,28,235); border: 1px solid #555; border-radius: 4px;",
      titleTxtColor = "#e6c35c",
    })
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
  M.helpContainer:show()
  local cols = M.pageCols(M.helpPg)
  local all = { segsToDecho({ header("help", "", math.min(cols, 100), title) })[1] }
  for _, l in ipairs(lines) do all[#all + 1] = (fmt == "cecho") and M.cechoToDecho(l) or l end
  M.pageShow(M.helpPg, all, "decho", links)
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

function M.loadItems()
  migrate(M.itemsFile, "softbunsos_items.lua")
  migrate(M.itemsFile, "mmformat_items.lua")
  local t = {}
  if io.exists(M.itemsFile) then pcall(table.load, M.itemsFile, t) end
  M.items, M.recent, M.eqNames = t.items or {}, t.recent or {}, t.eq or {}
  M.pinned = t.pinned
end
function M.saveItems()
  table.save(M.itemsFile, { items = M.items, recent = M.recent, eq = M.eqNames, pinned = M.pinned })
end

function M.remember(it)
  local copy = {}
  for k, v in pairs(it) do
    if k ~= "desc" and k ~= "other" and k ~= "header" and k ~= "relics" then copy[k] = v end
  end
  copy.seen = os.time()
  M.items[it.name] = copy
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
  for n, it in pairs(M.items) do if n:lower():find(q, 1, true) then return it end end
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

function M.compareLines(a, b, width)
  local out = {}
  local cw = math.max(8, math.min(20, math.floor((width - 16 - 10) / 2)))
  local function cut(s, n) s = tostring(s); n = n or cw; return ulen(s) > n and (s:sub(1, n - 1) .. "…") or s end
  out[#out + 1] = { { C.rule, "── " }, { C.title, "Compare " }, { C.rule, string.rep("─", math.max(2, width - 12)) } }
  out[#out + 1] = { { C.dim, " A  " }, { C.item, a.name } }
  out[#out + 1] = { { C.dim, " B  " }, { C.item, b.name } }
  out[#out + 1] = { { C.dim, pad("", 16) .. pad("A", cw + 2) .. pad("B", cw + 2) .. "B vs A" } }
  for _, r in ipairs(M.compareRows(a, b)) do
    local dcol = r[5] > 0 and C.plus or (r[5] < 0 and C.minus or C.dim)
    local acol = r[5] < 0 and C.plus or C.item
    local bcol = r[5] > 0 and C.plus or C.item
    out[#out + 1] = { { C.key, pad(cut(r[1], 15), 16) }, { acol, pad(cut(r[2]), cw + 2) },
                      { bcol, pad(cut(r[3]), cw + 2) }, { dcol, r[4] } }
  end
  return out
end


-- entry: when given, the comparison is added to that Inspector page
function M.compare(a, b, entry)
  if not a or not b then return false end
  if entry then
    entry.lines[#entry.lines + 1] = {}
    addAll(entry.lines, M.compareLines(a, b, M.viewCols()))
  elseif M.cfg.window then
    M.viewAdd({ lines = M.compareLines(a, b, M.viewCols()), links = {} })
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
  if not it then return cecho("\n<dim_grey>[<orange>sbo<dim_grey>]<reset> no remembered item matches that\n") end
  M.pinned = it.name; M.saveItems()
  cecho("\n<dim_grey>[<orange>sbo<dim_grey>]<reset> pinned: " .. it.name .. " - items you look at next are compared against it (sbo unpin to stop)\n")
end

function M.compareNames(qa, qb)
  local a, b = M.findItem(qa), M.findItem(qb)
  if not a then return cecho("\n<dim_grey>[<orange>sbo<dim_grey>]<reset> no remembered item matches: " .. tostring(qa) .. "\n") end
  if not b then return cecho("\n<dim_grey>[<orange>sbo<dim_grey>]<reset> no remembered item matches: " .. tostring(qb) .. "\n") end
  M.compare(a, b)
end

-- after an item look: remember it, offer links, auto-compare
function M.afterItem(raw, entry)
  local ok, it = pcall(M.parseItem, raw)
  if not ok or not it or not it.name then return end
  M.remember(it)
  it = M.items[it.name]
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
  local total = below and (h * 2) or h
  setBorderBottom(total)
  M.bar:move(left, H - total)
  M.bar:resize(W - left - right, h)
  -- the top line takes space above any top border something else already uses, and gives it back after
  if atTop then
    if not M.topTaken then
      local okT, t = pcall(getBorderTop)
      M.baseTop = (okT and tonumber(t)) or 0
      M.topTaken = true
    end
    setBorderTop(M.baseTop + h)
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

-- `sbo session`: a summary page in the Inspector
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
    if sc.tnl then c.tnl = tonumber((sc.tnl:gsub(",", ""))); c.exp = tonumber((sc.exp:gsub(",", ""))) end
  end
  for _, l in ipairs(raw) do
    for key, _, mx in l:gmatch("([%a][%a ]-):%s+(%-?%d+)/(%d+)") do
      local k = trim(key)
      if M.maxNames[k] then M.cfg.maxes[M.maxNames[k]] = tonumber(mx) end
    end
  end
  M.saveSettings()
end

local barColors = { hp = "tomato", sp = "light_sky_blue", st = "gold" }
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
  if S.kills0 and S.killsNow then
    segs[#segs + 1] = { C.plus, tostring(S.killsNow - S.kills0) }
    segs[#segs + 1] = { C.dim, "/" }
    segs[#segs + 1] = { C.minus, tostring((S.deathsNow or 0) - (S.deaths0 or 0)) }
  else
    segs[#segs + 1] = { C.dim, "-" }
  end
  local rate = M.expRate()
  segs[#segs + 1] = dot
  segs[#segs + 1] = { C.num, rate and tostring(fl(rate)) or "-" }
  segs[#segs + 1] = { C.dim, " xp/hr" }
  return segs
end

function M.drawSessionBar()
  if not M.sbar or not M.cfg.barSession or not M.cfg.bar or M.barCollapsed then return end
  barEcho(M.segsToDecho({ M.sessionSegs() })[1], M.sbar)
end

function M.drawBar()
  if not M.bar or not M.bar.rawEcho or not M.lastPromptText then return end
  if M.cfg.barMode == "raw" or #M.parsePrompt(M.lastPromptText).vals == 0 then
    -- drop the game's (black) text background so the bar's tint shows through
    local d = (M.lastPromptDecho or M.lastPromptText):gsub("<(%d+,%d+,%d+):[%d,]+>", "<%1>")
    barEcho(d)
    return
  end
  local p = M.parsePrompt(M.lastPromptText)
  M.cfg.maxes = M.cfg.maxes or {}
  local segs = {}
  for _, tag in ipairs(p.tags) do
    segs[#segs + 1] = { tag == "SAFE" and C.plus or C.key, tag }
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

function M.barUpdate(d)
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
  M.cap.maxTimer = tempTimer(M.cfg.maxTime, function() M.finish("maxtime") end)
end

function M.onSend(_, cmd)
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

function M.onLine()
  local cap = M.cap
  pcall(M.observe, line)
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
      send("c", false)
    end
    return   -- otherwise leave it in the main window so you can answer it
  end
  if isPromptLine() then
    if cap and #cap.plain > 0 then M.finish("prompt") end
    if M.cfg.bar then
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

  if #cap.plain == 0 and not heldPrompt then
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
          cecho("main", "<dim_grey>[sbo] help" .. (cap.target ~= "" and (" " .. cap.target) or "") ..
            " → help window<reset>\n")
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
      local lines = worth and M.format(cap.kind, cap.target, cap.plain, columns("main"), cap.decho)
      if lines then
        render("main", lines)
      else
        for _, d in ipairs(cap.decho) do decho("main", d .. "\n") end
      end
      if promptDecho then decho("main", promptDecho) end
      if heldPrompt then decho("main", heldPrompt) end
    end
    local entry
    if worth and M.cfg.window then
      local lines = M.format(cap.kind, cap.target, cap.plain, M.viewCols(), cap.decho)
      if lines then entry = { lines = lines, links = {} } end
    end
    if cap.kind == "eq" then M.updateEqNames(cap.plain) end
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
local function say(msg) cecho("\n<dim_grey>[<orange>sbo<dim_grey>]<reset> " .. msg .. "\n") end

function M.help()
  -- collect the text, then show it in the help window (or the main window)
  local buf = {}
  local function cecho(a) buf[#buf + 1] = a end
  cecho("\n<orange>Soft Bun's Oven<reset> <dim_grey>v" .. M.version .. " by softbuns :: bakes raw game output into something edible<reset>\n")
  cecho([[
  <khaki>sbo on|off<reset>                enable / disable capturing
  <khaki>sbo main replace|keep<reset>     replace = show formatted text in main window instead of the raw text
                            keep    = leave the main window untouched
  <khaki>sbo window on|off<reset>         floating Inspector window (drag/resize it; position is remembered)
  <khaki>sbo clear<reset>                 clear the Inspector's history
  <khaki>sbo raw<reset>                   reprint the last capture exactly as the game sent it
  <khaki>sbo samples on|off<reset>        log raw captures to oven_samples.txt (helps tune the layout)
  <khaki>sbo prompt [lua pattern]<reset>  set your prompt pattern (blank = telnet GA only)
  <khaki>sbo font [size]<reset>           Inspector and help window font size (no size = default)
  <khaki>sbo test<reset>                  show a demo
  <khaki>sbo compare<reset>               compare the last two items you looked at
  <khaki>sbo compare [a] vs [b]<reset>    compare two remembered items by (part of) their names
  <khaki>sbo pin [name]<reset> / <khaki>unpin<reset>    compare every item you look at against this one
  <khaki>sbo autocompare on|off<reset>    compare looked-at items with what you wear in that slot
  <khaki>sbo items<reset>                 list remembered items
  <khaki>sbo session [reset]<reset>       exp gained, exp/hour, time and kills to next level
  <khaki>sbo gamecolors on|off<reset>     keep the game's own colours on item names
  <khaki>sbo eqstats on|off<reset>        AR and affects of each worn item in eq (look at an item once to fill it in)
  <khaki>sbo empty on|off<reset>          show empty equipment slots in eq
  <khaki>sbo donation on|off<reset>       show / hide empty donation-only slots (amulet, face, aura)
  <khaki>sbo slots short|full<reset>      short slot names in eq tables (finger, neck…) or the game's full ones
  <khaki>sbo helpwindow on|off<reset>     game help pages (and this list) in their own window
  <khaki>sbo bar on|off<reset>            show the prompt in a fixed bar at the bottom instead of in the text
  <khaki>sbo bar gauges|raw<reset>        prompt bar as gauges, or the prompt exactly as the game sends it
  <khaki>sbo bar session on|off<reset>    session time, exp/hour, level ETA, kills (on the bar when it fits)
  <khaki>sbo bar session full|short<reset> time, k/d and xp/hr - or just xp/hr
  <khaki>sbo bar session top|bottom<reset> where they go when they don't fit: top of the screen or under the bar
  <khaki>sbo bar bg [r g b]<reset>        prompt bar background colour (no numbers = default)
  <khaki>sbo bar blanks on|off<reset>     keep (on) or remove (off) the blank line the game puts before each prompt
  <khaki>sbo bar width [n]<reset>         length of each gauge (no number = default, 10)
  <khaki>sbo bar lines [n]<reset> / <khaki>font [n]<reset>  prompt bar height / font size (no number = default)
  <khaki>sbo update<reset>                get the latest version from GitHub (settings are kept)
  <khaki>sbo update auto on|off<reset>    install new versions automatically (checks every 2 minutes)
  <khaki>sbo update force<reset>          reinstall the latest version even if you already have it
  <khaki>sbo update [file]<reset>         install a local .mpackage file instead
]])
  cecho(string.format("\n<dim_grey>settings: enabled=%s main=%s window=%s helpwindow=%s bar=%s samples=%s<reset>\n",
    tostring(M.cfg.enabled), M.cfg.main, tostring(M.cfg.window), tostring(M.cfg.helpWindow),
    tostring(M.cfg.bar), tostring(M.cfg.samples)))
  local text = table.concat(buf)
  if M.cfg.helpWindow then
    local lines = {}
    for l in (text:gsub("^\n", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
    M.helpPage("Soft Bun's Oven", lines, "cecho")
    _G.cecho("main", "<dim_grey>[sbo] command list → help window<reset>\n")
  else
    _G.cecho("main", text)
  end
end

M.demo = {
  eq = {
    "You are using:",
    "<worn on finger>     the wedding ring of the caretaker's wife (new)",
    "<worn on finger>     a bronze ring (new)",
    "<worn around neck>   a nefarious crab-shaped amulet (new)",
    "<worn around neck>   an artifact from a galeb duhr (new)",
    "<worn on torso>      a platinum breastplate (new)",
    "<worn on head>       a well-used inhaler (new)",
    "<worn on legs>       a pair of platinum thighguards (new)",
    "<worn on hands>      a pair of gloves (new)",
    "<worn on arms>       copper armbands (new)",
    "<worn as shield>     a tarnished copper shield (new)",
    "<over shoulders>     a vampire's cape (new)",
    "<worn around waist>  a dwarven girdle (new)",
    "<held on hip>        a magical belt pouch (new)",
    "<worn around wrist>  a bracer of the Beltan knights (new)",
    "<worn around wrist>  a fine opal bracelet (new)",
    "<left hand>          a swirling crimson orb (new)",
    "",
    "Current Armor Resistance (AR):",
    "(Head    )  4   (Reduces damage taken by 3.000%)",
    "(Torso   )  3   (Reduces damage taken by 2.250%)",
    "(Arms    )  3   (Reduces damage taken by 2.250%)",
    "(Legs    )  6   (Reduces damage taken by 4.500%)",
    "(Tail    )  1   (Reduces damage taken by 0.750%)",
    "Your value if CPKed would be 25,900gp. You have a 34% chance to resist a critical hit.",
    "You have a 1% chance to reduce spell damage taken by 35%.",
    "",
    "Equipped weapon damage:",
    "With hand to hand, you will deal Low water damage with Max accuracy, at Min range, with a High chance to crit for 2x damage.",
    "19 Damage: (+17 from weapon) (+2 from skill & strength) ",
    "98 Accuracy: (+22 from level) (+25 from weapon skill) (+45 from fists) (+5 from agility) (+1 from personality) (+18 when martial arts activates) ",
    "2 Range:  (+2 from hand to hand)",
    "22% Critical Hit chance:  (+22 from hand to hand)",
  },
  item = {
    "You focus your powers of observation on a crystal necklace:",
    "Item 'a crystal necklace' is type armor, alignment 0, made of crystal (in (new) condition),[Study][LTB]",
    "has keywords 'crystal necklace wisehart', equipped around the neck.",
    "This item weighs 0 stones and 17 pebbles, and is valued at 6,000 gold. {Cat. 2}",
    "This level 8 item has the attributes: none",
    "Armor resistance is 1.",
    "Relics: ",
    "  Small (1/1):",
    "    a tattooed bit of dwarven flesh (new) [Vanishes Sat May  8 01:11:33 2027]",
    "      Affects saving-spell by 1.",
    "Affects agility by 1.",
    "*This item may be repaired 6 times.",
    "This beautiful necklace made of glinting crystal once belonged to Saint",
    "Wisehart, a champion of good.  The necklace, composed of a silver chain with",
    "a downward pointing, triangular pattern of crystals, shines gloriously,",
    "untouched by time, symbolizing the persistence of clarity.  ",
  },
  contents = {
    "A cute little pixie bag contains:",
    "     a rugged wooden lance (new)",
    "     a purple cloak (new)",
    "     a practice staff (new)",
    "     a trophy that looks like the boss, Atrascus the King Crab [2026 Edition] (new)",
    "(  2) a green mushroom (fresh)",
    "     a torch (new) (unlit)",
    "( 10) a scroll of 'cure light' (new)",
    "     a trophy that looks like the boss, the Forest Guardian [2026 Edition] (new)",
    "A total of 18 (30 max) items weighing 2 sts, 84 pbs (5 sts, 0 pbs max).",
  },
}

function M.test()
  for _, k in ipairs({ "eq", "item", "contents" }) do
    local cap = { kind = k, target = "", plain = M.demo[k] }
    local w = columns("main")
    if M.cfg.main == "replace" then render("main", M.format(cap.kind, cap.target, cap.plain, w)) end
    if M.cfg.window then
      M.viewAdd({ lines = M.format(cap.kind, cap.target, cap.plain, M.viewCols()), links = {} })
    end
  end
end

-- numeric setting argument: a number, or blank for the default
function M.numArg(v, key)
  v = trim(v or "")
  if v == "" then return M.defaults[key] end
  local n = tonumber(v)
  if n and n >= 0 then return n end
end

function M.command(args)
  args = trim(args or "")
  local a, b = args:match("^(%S*)%s*(.-)$")
  a = a:lower()
  local onoff  -- (careful: `x and false or nil` is always nil in Lua)
  if b == "on" then onoff = true elseif b == "off" then onoff = false end
  if a == "" or a == "help" then return M.help()
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
  elseif a == "test" then M.test()
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
  elseif a == "helpwindow" and onoff ~= nil then
    M.cfg.helpWindow = onoff
    if not onoff and M.helpContainer then M.helpContainer:hide() end
    say("help window " .. b)
  elseif a == "slots" and (b == "short" or b == "full") then
    M.cfg.slotNames = b; say("slot names: " .. b)
  elseif a == "session" then
    if b == "reset" then M.sess = { start = os.time(), gained = 0 }; say("session counters reset"); return end
    if M.cfg.window then M.viewAdd({ lines = M.sessionLines(M.viewCols()), links = {} })
    else render("main", M.sessionLines(columns("main"))) end
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
      say("session details " .. val .. (M.cfg.bar and "" or " (they show when the bar is on: sbo bar on)"))
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
  if v then return "avail", "↑ v" .. v .. " available - sbo update", v end
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
    cecho("<dim_grey>[sbo] " .. long .. "<reset>\n")
  end
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
      or "off: you're told when a new version is out (sbo update auto on to install them automatically)"))
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
      local hex = body:match("(%x+) refs/heads/" .. M.BRANCH .. "%f[%z%s]") or body:match("(%x+) refs/heads/" .. M.BRANCH)
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
        M.notify("v" .. latest .. " is available (you have v" .. M.version .. ") - type sbo update")
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
function M.teardown()
  if M.handlers then for _, h in ipairs(M.handlers) do killAnonymousEventHandler(h) end end
  if M.lineTrigger then killTrigger(M.lineTrigger) end
  if M.alias then killAlias(M.alias) end
  M.handlers, M.lineTrigger, M.alias = nil, nil, nil
  if M.pollTimer then killTimer(M.pollTimer); M.pollTimer = nil end
  if M.sessTimer then killTimer(M.sessTimer); M.sessTimer = nil end
end

function M.init()
  M.updating = nil
  M.teardown()
  M.dropPages()
  M.loadSettings()
  M.handlers = {
    registerAnonymousEventHandler("sysDataSendRequest", M.onSend),
    registerAnonymousEventHandler("sysUninstallPackage", function(_, pkg)
      if pkg == "Oven" then
        M.teardown()
        if M.updating then return end   -- an update: the new version takes the windows over
        if M.container then M.container:hide() end
        if M.helpContainer then M.helpContainer:hide() end
        if M.bar then M.bar:hide(); setBorderBottom(0) end
        if M.sbar then M.sbar:hide() end
        if M.topTaken then setBorderTop(M.baseTop or 0); M.topTaken = nil end
      end
    end),
  }
  M.loadItems()
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysWindowResizeEvent", function() M.layoutBar(); pcall(M.drawBar) end)
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysDownloadDone", M.onDownload)
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysDownloadError", M.onDownload)
  for _, v in ipairs({ "LEVEL", "EXPERIENCE", "EXPERIENCE_MAX", "EXPERIENCE_TNL", "EXPERIENCE_TO_LEVEL" }) do
    M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("msdp." .. v, M.onMsdp)
  end
  M.lineTrigger = tempRegexTrigger("^", function() M.onLine() end)
  M.alias = tempAlias("^(?:sbo|oven)(?:\\s+(.*))?$", function() M.command(matches[2]) end)
  if M.cfg.window and M.container then M.container:show() end
  if M.cfg.bar then M.showBar(true) end
  M.startUpdatePoll()
  if not M.booted then
    M.booted = true
    tempTimer(8, function() M.checkForUpdate() end)
    cecho("\n<dim_grey>[<orange>Soft Bun's Oven<dim_grey>] v" .. M.version ..
      " by softbuns :: preheated :: raw stream in, baked output out :: type <khaki>sbo<dim_grey> for commands<reset>\n")
  end
end

M.init()
