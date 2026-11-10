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

M.version = "0.16.9"
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
  questHudSide = "right",    -- quest HUD corner: right or left (top of the game text area)
  questHudOpacity = 100,     -- quest HUD background opacity, 0-100
  questHudBlurb = false,     -- show each quest's description (hints) in the HUD
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
  { word = "skill",     min = 3, kind = "skills" },
  { word = "practice",  min = 3, kind = "skills" },
  { word = "train",     min = 3, kind = "skills" },
  -- recorded only (shown as the game sends it) until a layout exists
  { word = "quest",     min = 3, kind = "quest" },
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

-- print an Oven line in the main window: a line break first only when the last line
-- already has text on it (a prompt, say), so there's never an empty line before it
function M.log(text)
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

function M.parseQuests(raw)
  local list, detail, other = {}, nil, {}
  local inPhases = false
  for idx, l in ipairs(raw) do
    local t = trim(l)
    local id, name, done, total = t:match("^Quest #(%d+)%s*:%s*(.-)%s*%(%s*(%d+)/(%d+)%s+complete%)%.?$")
    if id then
      list[#list + 1] = { id = id, name = name, done = tonumber(done), total = tonumber(total), idx = idx }
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
        elseif detail.inRewards and (t:match("^%*?Up to") or t:match("^[%d,]+ %a")) then
          detail.rewardText = (detail.rewardText and (detail.rewardText .. " ") or "") .. t:gsub("^%*", "")
          if t:match("%.$") then detail.inRewards = false end
        elseif t:match("time limit") then detail.limit = t:gsub("%.$", "")
        elseif t:match(" consists of:$") then inPhases = true
        elseif pn then
          local isDone = ptext:sub(1, 1) == "*"
          ptext = ptext:gsub("^%*", ""):gsub("%.$", "")
          local text, area = ptext:match("^(.-)%s*%[(.-)%]$")
          detail.phases[#detail.phases + 1] = { n = tonumber(pn), text = text or ptext, area = area, done = isDone }
        elseif t ~= "" and not inPhases then
          detail.desc[#detail.desc + 1] = rtrim(l)   -- keep indentation (lists, continuation lines)
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
function M.rememberQuests(q)
  local now = os.time()
  if #q.list > 0 then
    local active = {}
    for _, e in ipairs(q.list) do
      local Q = M.quests[e.id] or {}
      Q.name, Q.done, Q.total, Q.seen = e.name, e.done, e.total, now
      M.quests[e.id] = Q
      active[e.id] = true
    end
    -- a pinned quest missing from your active list is finished (or abandoned)
    for id in pairs(M.cfg.questPins or {}) do
      if not active[id] then
        M.cfg.questPins[id] = nil
        M.notifyQuest((M.quests[id] and M.quests[id].name or ("#" .. id)) .. " is no longer active - unpinned")
      end
    end
  end
  if q.detail then
    local d = q.detail
    local Q = M.quests[d.id] or {}
    for k, v in pairs(d) do Q[k] = v end
    if d.total and d.done < d.total then Q.complete = nil end
    Q.seen = now
    M.quests[d.id] = Q
  end
  M.cfg.quests = M.quests     -- kept between sessions
  M.saveSettings()
  M.drawQuestTracker()
end

function M.notifyQuest(msg)
  if M.cfg.bar and M.bar and M.bar.rawEcho then
    M.walkNote = msg; pcall(M.drawBar)
    tempTimer(8, function() if M.walkNote == msg then M.walkNote = nil; pcall(M.drawBar) end end)
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
  local q = M.parseQuests(raw)
  if #q.list == 0 and not q.detail then return M.formatters.generic(raw, width) end
  M.rememberQuests(q)
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
    if #d.desc > 0 then paragraphs(out, d.desc, width) end
    if #d.phases > 0 then
      subhead(out, "Phases")
      local np = nextPhase(d)
      for _, p in ipairs(d.phases) do
        local mark = p.done and { C.plus, " ✓ " } or (p == np and { M.REC or C.title, " ▶ " } or { C.dim, "   " })
        local row = { mark, { C.dim, string.format("%d. ", p.n) },
                      { p.done and C.dim or (p == np and C.item or C.text), p.text } }
        if p.area then row[#row + 1] = { C.dim, "  [" .. p.area .. "]" } end
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

function M.questPin(id, on)
  M.cfg.questPins = M.cfg.questPins or {}
  if id == "all" then
    for qid, Q in pairs(M.quests) do if Q.done and Q.total and Q.done < Q.total then M.cfg.questPins[qid] = on or nil end end
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

local function questFinished(Q)
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

local HUD_WRAP = 64

-- one quest's lines (html) and their widest width in characters:
-- the name and progress, every step still to do (the next one marked), and optionally the blurb
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
  add((finished and span(C.plus, "✓ ") or "") .. span(C.dim, "#" .. id .. " ")
    .. span(finished and C.dim or C.item, name) .. "&nbsp;&nbsp;" .. bar,
    ulen(name) + ulen(id) + 4 + (Q.total and 13 or 0) + (finished and 2 or 0))
  if finished then
    add(span(C.plus, " complete") .. span(C.dim, " · click to clear"), 28)
  elseif Q.phases then
    local first = true
    for _, ph in ipairs(Q.phases) do
      if not ph.done then
        local label = string.format("%d. %s", ph.n, ph.text) .. (ph.area and (" · " .. ph.area) or "")
        for i, l in ipairs(hudWrap(label, HUD_WRAP, ulen(tostring(ph.n)) + 2)) do
          local mark = (i == 1) and (first and span(M.REC or C.title, " ▶ ") or "   ") or "   "
          add(mark .. span(first and C.item or C.text, l), ulen(l) + 3)
        end
        first = false
      end
    end
  else
    add(span(C.dim, " (click to load its steps)"), 27)
  end
  -- the quest's blurb (often holds hints), dimmed
  if M.cfg.questHudBlurb and Q.desc and #Q.desc > 0 and not finished then
    local para = {}
    local function flush()
      if #para > 0 then
        for _, l in ipairs(hudWrap(table.concat(para, " "), HUD_WRAP, 0)) do add(span(C.dim, " " .. l), ulen(l) + 1) end
        para = {}
      end
    end
    add("", 0)
    for _, l in ipairs(Q.desc) do
      if trim(l) == "" then flush()
      elseif l:match("%S%s%s%s+%S") or l:match("^%s%s%s%s+%S") or l:match("^%s*[%*%-] ") or trim(l):match(":$") then
        flush()   -- list lines and "You can find:" headings keep their own line, spacing and all
        local line = rtrim(l)
        if ulen(line) <= HUD_WRAP + 12 then
          add(span(C.dim, " " .. line:gsub(" ", "\194\160")), ulen(line) + 1)
        else
          for _, w in ipairs(hudWrap(line, HUD_WRAP, 4)) do add(span(C.dim, " " .. w), ulen(w) + 1) end
        end
      else
        para[#para + 1] = trim(l)
      end
    end
    flush()
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
function M.drawQuestTracker()
  if M.questContainer then M.questContainer:hide() end   -- the framed window of 0.14.0
  local pins = M.cfg.questPins or {}
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
    pcall(function() M.questHud:setToolTip("drag to move · click a quest to refresh it · click a finished quest to clear it") end)
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
  M.questHudSize = { w = math.min(600, widest * cw + 24), h = total }
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

-- a click on a quest card: a finished quest is cleared, any other quest is refreshed;
-- a click on the frame (between cards) refreshes them all
function M.questHudClick(id)
  if not id then return M.questRefresh("all") end
  local Q = M.quests[id] or {}
  if questFinished(Q) then
    M.questPin(id, false)
    M.notifyQuest((Q.name or ("#" .. id)) .. " cleared from the quest HUD")
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
      if M.cfg.questPins and M.cfg.questPins[id] then
        M.notifyQuest(name .. " complete - turn it in, then click it to clear")
      end
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
function M.questRefresh(id)
  if id == "all" then
    local ids = {}
    for qid in pairs(M.cfg.questPins or {}) do ids[#ids + 1] = qid end
    for i, qid in ipairs(ids) do tempTimer((i - 1) * 1.5, function() M.questRefresh(qid) end) end
    return
  end
  M.quietQuest = true
  send("quest info " .. id, false)
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
  if M.raiseQuestHud then M.raiseQuestHud() end
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
  if not it then return M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> no remembered item matches that") end
  M.pinned = it.name; M.saveItems()
  M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> pinned: " .. it.name .. " - items you look at next are compared against it (sbo unpin to stop)")
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
        if t:match("^You receive") or t:match("^You gain") then pcall(M.creditKillExp, n) end
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
  if M.walkNote then main[#main + 1] = { C.dim, "   walk " }; main[#main + 1] = { C.slot, M.walkNote } end
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
  if M.learning and kind == "item" then
    -- sbo learn: record the item, show nothing
    M.cap.quiet, M.cap.gag = true, true
    M.learning.started = true
  end
  M.cap.maxTimer = tempTimer(M.cfg.maxTime, function() M.finish("maxtime") end)
end

function M.onSend(_, cmd)
  pcall(M.noteLootCommand, cmd)
  pcall(M.noteEnterCommand, cmd)
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
  quest = function(t, l, cap)
    if not cap.questStarted then
      if t:match("^Quest #%d+") or t:match("^This quest %[%d+%]") or t:match("^Usage: quest")
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
      for _, x in ipairs(R) do f:write(x, "\n") end
      f:write(l, "\n===== end\n\n")
      f:close()
    end
  end
  R[#R + 1] = l
  if #R > 8 then table.remove(R, 1) end
end

function M.onLine()
  local cap = M.cap
  pcall(M.observe, line)
  pcall(M.noteRoomLine, line)
  pcall(M.noteKillContext, line)
  -- "(Mount: 764st)": your mount's stamina, sent just before each prompt while riding.
  -- It goes on the bar; it's never part of a command's output.
  local slain = line:match("^%s*(.-) has been slain!%s*$")
  if slain and slain ~= "" then pcall(M.recordKill, slain) end
  pcall(M.noteLootContext, line)
  local okL, loot = pcall(M.parseLoot, line)
  if okL and loot then pcall(M.recordLoot, loot) end
  if line:find("^%s*The Powers take pity on you and restore your soul to your body") then
    M.sess.deathsLive = (M.sess.deathsLive or 0) + 1
    pcall(M.noteRoomDeath)
    pcall(M.drawBar)
  end
  local doneQuest = line:match("^%s*All parts of your quest '(.+)' are complete%.?%s*$")
  if doneQuest then pcall(M.questMarkComplete, doneQuest) end
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

  if #cap.plain == 0 and not heldPrompt and not cap.quiet then
    local nxt = table.remove(M.queue, 1)
    if nxt then M.start(nxt[1], nxt[2], nxt[3]) end
    return
  end

  if cap.quiet and cap.quietKind == "quest" then
    -- tracker refresh: update the quest, draw nothing
    if reason == "prompt" and not M.cfg.bar then deleteLine() end
    pcall(function() M.rememberQuests(M.parseQuests(cap.plain)) end)
    if M.cfg.samples and #cap.plain > 0 then writeSample(cap) end
    local nxt = table.remove(M.queue, 1)
    if nxt then M.start(nxt[1], nxt[2], nxt[3]) end
    return
  end
  if cap.quiet then
    -- sbo learn: remember the item, draw nothing, keep the prompt out of the log too
    if reason == "prompt" and not M.cfg.bar then deleteLine() end
    local ok, it = pcall(M.parseItem, cap.plain)
    if ok and it and it.name then M.remember(it); M.learnStats.ok = M.learnStats.ok + 1
    else M.learnStats.fail = M.learnStats.fail + 1 end
    if M.cfg.samples and #cap.plain > 0 then writeSample(cap) end
    M.learning = nil
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
      M.pendingLinks = nil
      local lines = M.format(cap.kind, cap.target, cap.plain, M.viewCols(), cap.decho)
      if lines then entry = { lines = lines, links = M.pendingLinks or {} } end
      M.pendingLinks = nil
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
local function say(msg) M.log("<dim_grey>[<orange>sbo<dim_grey>]<reset> " .. msg) end

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
        M.notifyWalk("arrived")
      else
        M.walkStep()
      end
    elseif id ~= w.from then
      M.walk = nil
      M.notifyWalk("stopped: ended up somewhere unexpected")
    end
  end
end

function M.notifyWalk(msg)
  if M.cfg.bar and M.bar and M.bar.rawEcho then
    M.walkNote = msg; pcall(M.drawBar)
    tempTimer(6, function() if M.walkNote == msg then M.walkNote = nil; pcall(M.drawBar) end end)
  else
    say("walk " .. msg)
  end
end

function M.walkStep()
  local w = M.walk
  if not w then return end
  w.from = M.mapRoom
  local mine, step = w, w.step
  send(w.dirs[w.step], false)
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
  local fl = (M.cfg.roomFlags or {})[tostring(id)]
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
  local any = false
  local MAX = 8
  -- notable NPCs ([QUEST] [SHOP] [TRAINER] ...)
  local npcs = {}
  for _, n in pairs((M.cfg.roomNpcs or {})[tostring(id)] or {}) do npcs[#npcs + 1] = n end
  table.sort(npcs, function(a, b) return (a.last or 0) > (b.last or 0) end)
  if #npcs > 0 then
    any = true
    row(); row({ M.REC or C.title, "▸ Notable here" })
    for i, n in ipairs(npcs) do
      if i > MAX then row({ C.dim, string.format("  … and %d more", #npcs - MAX) }); break end
      local r = { { C.dim, "  " } }
      for _, t in ipairs(n.tags or {}) do r[#r + 1] = { C.flag, "[" .. t .. "] " } end
      r[#r + 1] = { C.text, n.text }
      out[#out + 1] = r
    end
  end
  -- "enter ..." commands that work here
  local enters = {}
  for cmd, e in pairs((M.cfg.roomEnters or {})[tostring(id)] or {}) do enters[#enters + 1] = { cmd = cmd, to = e.to } end
  table.sort(enters, function(a, b) return a.cmd < b.cmd end)
  if #enters > 0 then
    any = true
    row(); row({ M.REC or C.title, "▸ Ways in" })
    for _, e in ipairs(enters) do
      local dest = e.to and roomExists(e.to) and getRoomName(e.to) or nil
      row({ C.key, "  " .. e.cmd }, { C.dim, "  → " .. (dest and (dest .. "  #" .. e.to) or ("#" .. tostring(e.to))) })
    end
  end
  -- kills
  local kills = {}
  for _, e in pairs((M.cfg.roomKills or {})[tostring(id)] or {}) do kills[#kills + 1] = e end
  table.sort(kills, function(a, b) return a.count ~= b.count and a.count > b.count or (a.last or 0) > (b.last or 0) end)
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
  local found, order = {}, {}
  for _, e in ipairs(M.cfg.loot or {}) do
    if e.room == id then
      local k = e.item:lower()
      local f = found[k]
      if not f then f = { item = e.item, count = 0, who = {} }; found[k] = f; order[#order + 1] = f end
      f.count = f.count + (e.count or 1)
      f.last = math.max(f.last or 0, e.t or 0)
      f.who[e.who or "?"] = true
    end
  end
  table.sort(order, function(a, b) return (a.last or 0) > (b.last or 0) end)
  if #order > 0 then
    any = true
    row(); row({ M.REC or C.title, "▸ Picked up here" })
    for i, f in ipairs(order) do
      if i > MAX then row({ C.dim, string.format("  … and %d more (sbo loot #%d)", #order - MAX, id) }); break end
      local who = {}
      for w in pairs(f.who) do who[#who + 1] = w end
      table.sort(who)
      row({ C.num, string.format("  %3d× ", f.count) }, { C.item, f.item },
          { C.dim, "  " .. table.concat(who, ", ") .. " · " .. ago(f.last) })
    end
  end
  -- deaths
  local deaths = (M.cfg.roomDeaths or {})[tostring(id)] or {}
  if #deaths > 0 then
    any = true
    row(); row({ C.minus, "▸ You died here" }, { C.dim, "  " .. #deaths })
    for i = #deaths, math.max(1, #deaths - MAX + 1), -1 do
      local d = deaths[i]
      row({ C.text, "  " .. (d.level and ("at level " .. d.level) or "level unknown") .. (d.total and (" (total " .. d.total .. ")") or "") },
          { C.dim, "  " .. ago(d.t) })
    end
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

-- Notable NPCs: room lines carrying all-caps tags like [QUEST] [SHOP] [TRAINER], kept per room.
-- Lines are gathered until the prompt and filed under the room you're in at the prompt
-- (the room number may arrive just before or just after the room's text).
local NOT_TAGS = { CRIT = true }
M.roomLineBuf = M.roomLineBuf or {}
M.npcCtxLogged = M.npcCtxLogged or 0

-- "*[Shop] A hunched-over senior citizen sits on a blanket, peddling his wares."
-- tags open the line (after an optional "*"), each a capitalised word or words
local function npcTags(l)
  local rest = l:gsub("^%s*%*?%s*", "")
  local tags = {}
  while true do
    local t, after = rest:match("^%[(%u[%a %-]*%a)%]%s*(.*)$")
    if not t then break end
    if not NOT_TAGS[t:upper()] and ulen(t) >= 3 then tags[#tags + 1] = t end
    rest = after
  end
  local text = trim((rest:gsub("%s+", " ")))
  if #tags == 0 or text == "" or ulen(text) > 160 then return end
  -- channels and speech aren't room occupants
  for _, v in ipairs({ " tells ", " says", " asks", " exclaims", " yells", " shouts", " whispers", " chats", " replies", "%a: " }) do
    if text:find(v) then return end
  end
  return tags, text
end

-- the prompt's tags describe the room ([SHOP] [SAFE] [Library]...), except [Mail], which is you
local NOT_ROOM_FLAGS = { mail = true }
function M.noteRoomFlags(id, l)
  if not id then return end
  local before = l:match("^(.-)<") or l
  local flags = {}
  for t in before:gmatch("%[([^%]]+)%]") do
    if not NOT_ROOM_FLAGS[t:lower()] then flags[#flags + 1] = t end
  end
  M.cfg.roomFlags = M.cfg.roomFlags or {}
  local key, old = tostring(id), M.cfg.roomFlags[tostring(id)]
  local was = old and table.concat(old.tags or {}, ",") or nil
  if was == table.concat(flags, ",") then return end
  if #flags == 0 and not old then return end
  M.cfg.roomFlags[key] = #flags > 0 and { tags = flags, last = os.time() } or nil
  M.saveSettings()
end

function M.noteRoomLine(l)
  if isPromptLine() then
    local id = M.currentRoom()
    pcall(M.noteRoomFlags, id, l)
    local buf = M.roomLineBuf
    M.roomLineBuf = {}
    if id and #buf > 0 then
      M.cfg.roomNpcs = M.cfg.roomNpcs or {}
      local book = M.cfg.roomNpcs[tostring(id)] or {}
      M.cfg.roomNpcs[tostring(id)] = book
      for _, e in ipairs(buf) do
        local key = e.text:lower()
        local n = book[key]
        if not n then
          local count = 0
          for _ in pairs(book) do count = count + 1 end
          if count < 20 then n = { text = e.text, seen = 0 }; book[key] = n end
        end
        if n then n.tags = e.tags; n.seen = n.seen + 1; n.last = os.time() end
      end
      M.saveSettings()
    end
    pcall(M.checkEnter, id)
    return
  end
  local tags, text = npcTags(l)
  if tags then
    M.roomLineBuf[#M.roomLineBuf + 1] = { tags = tags, text = text }
    if M.cfg.samples and M.npcCtxLogged < 15 then
      M.npcCtxLogged = M.npcCtxLogged + 1
      local f = io.open(M.samplesFile, "a")
      if f then f:write("===== " .. os.date("%Y-%m-%d %H:%M:%S") .. " | kind=npcctx | cmd=\n" .. l .. "\n===== end\n\n"); f:close() end
    end
  end
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
  M.cfg.roomEnters = M.cfg.roomEnters or {}
  local book = M.cfg.roomEnters[tostring(p.from)] or {}
  M.cfg.roomEnters[tostring(p.from)] = book
  book[p.cmd] = { to = id, last = os.time() }
  M.saveSettings()
  if roomExists(p.from) and roomExists(id) then
    local ok, exits = pcall(getSpecialExitsSwap, p.from)
    if not (ok and type(exits) == "table" and exits[p.cmd]) then
      pcall(addSpecialExit, p.from, id, p.cmd)
    end
  end
end

-- the room's history: who was killed where
function M.noteRoomKill(key, name)
  local id = M.currentRoom()
  if not id then return end
  M.cfg.roomKills = M.cfg.roomKills or {}
  local book = M.cfg.roomKills[tostring(id)] or {}
  M.cfg.roomKills[tostring(id)] = book
  local e = book[key] or { name = name, count = 0 }
  book[key] = e
  e.count = e.count + 1
  e.last = os.time()
end

-- you died: "restore your soul to your body" happens where the body is, i.e. where you fell
function M.noteRoomDeath()
  local id = M.currentRoom()
  if not id then return end
  local c = M.cfg.char or {}
  M.cfg.roomDeaths = M.cfg.roomDeaths or {}
  local list = M.cfg.roomDeaths[tostring(id)] or {}
  M.cfg.roomDeaths[tostring(id)] = list
  list[#list + 1] = { t = os.time(), level = c.level, total = c.total }
  M.saveSettings()
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
  if M.cfg.window then M.viewAdd({ lines = out, links = links })
  else render("main", out) end
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
function M.mapWalkTo(id)
  id = tonumber(id)
  if not id or not roomExists(id) then return say("room #" .. tostring(id) .. " isn't on the map") end
  if not M.mapRoom then return say("Oven doesn't know where you are yet - move one room first") end
  M.mapShow(id)
  if not getPath(M.mapRoom, id) then return say("no route on the map from here to #" .. id) end
  local dirs, path = {}, {}
  for i, d in ipairs(speedWalkDir) do dirs[i] = d; path[i] = tonumber(speedWalkPath[i]) end
  if #dirs == 0 then return say("you're already there") end
  M.walk = { dirs = dirs, path = path, step = 1 }
  M.notifyWalk(string.format("%d step%s…", #dirs, #dirs == 1 and "" or "s"))
  M.walkStep()
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
  M.cfg.kills = M.cfg.kills or {}
  M.sess.killBook = M.sess.killBook or {}
  local t = os.time()
  for _, book in ipairs({ M.cfg.kills, M.sess.killBook }) do
    local e = killBook(book, key, name)
    e.count = e.count + 1
    e.last = t
  end
  M.sess.killsLive = (M.sess.killsLive or 0) + 1
  pcall(M.noteRoomKill, key, name)
  M.lastKill = { key = key, at = now() }
  M.saveSettings()
  pcall(M.drawBar)
end

-- exp gained within a few seconds of a kill is credited to it
function M.creditKillExp(n)
  local k = M.lastKill
  if not k or now() - k.at > 5 then return end
  for _, book in ipairs({ M.cfg.kills or {}, M.sess.killBook or {} }) do
    local e = book[k.key]
    if e then e.exp = (e.exp or 0) + n end
  end
  M.lastKill = nil
  M.saveSettings()
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
      out[#out + 1] = { { C.dim, string.format("  … and %d more (sbo kills all)", #rows - limit) } }
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
  killTable(out, "All time", M.cfg.kills, width, all and nil or 25)
  return out
end

---------------------------------------------------------------------------
-- Loot log: what you (or anyone with you) pick up, and the exact room it was in
---------------------------------------------------------------------------
local LOOT_KEEP = 500
-- "You get ..." lines that aren't items
local NOT_LOOT = { "^the feeling", "^a feeling", "^the sense", "^a sense", "^the impression", "^the idea",
                   "^nothing", "^hungry", "^thirsty", "^tired", "^up", "^dressed", "^undressed",
                   "^better", "^worse", "^lost", "^a chance", "^the chance", "^ready", "^experience" }

function M.parseLoot(l)
  l = trim(l)
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
  local log = M.cfg.loot or {}
  M.cfg.loot = log
  log[#log + 1] = e
  while #log > LOOT_KEEP do table.remove(log, 1) end
  M.saveSettings()
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
  local log = M.cfg.loot or {}
  local out, links, rooms = {}, {}, {}
  q = q and trim(q):lower() or ""
  local sessN = 0
  for _, e in ipairs(log) do if e.t >= (M.sess.start or 0) then sessN = sessN + 1 end end
  local title = q ~= "" and ("Loot: " .. q) or "Loot"
  out[1] = header("loot", "", width, title)
  local gold = M.sess.lootGold or 0
  out[#out + 1] = { { C.dim, string.format("%d pickup%s this session, %d logged in all", sessN, sessN == 1 and "" or "s", #log) },
                    gold > 0 and { C.num, "  ·  " .. M.commaNum(gold) .. " gold picked up" } or { C.dim, "" } }
  out[#out + 1] = {}
  local shown, limit = 0, all and LOOT_KEEP or 30
  local lastDay
  for i = #log, 1, -1 do
    local e = log[i]
    local hay = (e.item .. " " .. (e.who or "") .. " " .. (e.from or "") .. " " .. (e.roomName or "") .. " " .. (e.area or "") .. " #" .. tostring(e.room)):lower()
    if q == "" or hay:find(q, 1, true) then
      shown = shown + 1
      if shown > limit then
        out[#out + 1] = { { C.dim, "… more: sbo loot all" .. (q ~= "" and (" " .. q) or "") } }
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

-- sbo learn: look at every worn item Oven doesn't know yet (the "?" in eq), quietly
function M.learn()
  if #M.eqNames == 0 then return say("type eq first, so Oven knows what you're wearing") end
  M.learnQueue, M.learnStats = {}, { ok = 0, fail = 0 }
  local seen = {}
  for _, n in ipairs(M.eqNames) do
    if not M.items[n] and not seen[n] then seen[n] = true; M.learnQueue[#M.learnQueue + 1] = n end
  end
  if #M.learnQueue == 0 then return say("every item you're wearing is already known") end
  say("looking at " .. #M.learnQueue .. " worn item" .. (#M.learnQueue == 1 and "" or "s") .. "…")
  M.learnNext()
end

function M.learnNext()
  if not M.learnQueue then return end
  local name = table.remove(M.learnQueue, 1)
  if not name then
    local st = M.learnStats
    M.learnQueue = nil
    say(string.format("learned %d item%s%s", st.ok, st.ok == 1 and "" or "s",
      st.fail > 0 and string.format(" (%d couldn't be looked at)", st.fail) or ""))
    send("eq")   -- show the filled-in table
    return
  end
  M.learning = { name = name }
  local mine = M.learning
  send('look "' .. name .. '"', false)
  -- no reply at all? move on
  tempTimer(5, function()
    if M.learning == mine and not mine.started then
      M.learning = nil
      M.learnStats.fail = M.learnStats.fail + 1
      M.learnNext()
    end
  end)
end


-- the command list, grouped by what you want to do; `sbo help <section>` shows one section
M.helpSections = {
  { key = "start", title = "Getting started", rows = {
    { "sbo test", "see a demo of the layouts" },
    { "score  eq  look {item}", "just play: Oven bakes these (and i, aff, quest, prac, help…) as they arrive" },
    { "sbo raw", "the last output exactly as the game sent it" },
    { "sbo help {section}", "just one section: start gear quest map log bar window update" },
  } },
  { key = "gear", title = "Gear and items", rows = {
    { "sbo learn", "look at worn items Oven doesn't know yet (the ? in eq)" },
    { "sbo compare", "compare the last two items you looked at" },
    { "sbo compare {a} vs {b}", "compare two remembered items by part of their names" },
    { "sbo pin {name}  /  unpin", "compare everything you look at against one item (handy in shops)" },
    { "sbo autocompare on|off", "compare each looked-at item with what you wear in that slot" },
    { "sbo items", "list the items Oven remembers" },
    { "", "" },
    { "sbo eqstats on|off", "AR and affects column in eq" },
    { "sbo empty on|off", "show empty slots in eq" },
    { "sbo donation on|off", "show empty donation-only slots (amulet, face, aura)" },
    { "sbo slots short|full", "short slot names (finger, neck…) or the game's full ones" },
    { "sbo gamecolors on|off", "keep the game's own colours on item names" },
  } },
  { key = "quest", title = "Quests", rows = {
    { "sbo quest pin {id|all}", "put quests on the quest HUD (or click pin under quest info)" },
    { "sbo quest unpin {id|all}", "take them off (click a finished quest to clear it)" },
    { "sbo quest refresh [id]", "quietly re-check pinned quests (or click the HUD)" },
    { "sbo quest show|hide", "show / hide the quest HUD" },
    { "sbo quest hud blurb on|off", "add each quest's description, which often holds hints" },
    { "sbo quest hud left|right", "which top corner it sits in (reset: back there after dragging)" },
    { "sbo quest hud opacity [0-100]", "how see-through it is (no number = solid)" },
  } },
  { key = "map", title = "Map and walking", rows = {
    { "sbo map on|off", "follow you on the map; double-click a room to walk there" },
    { "sbo map panel on|off", "the map in its own window, with a search box and zoom buttons" },
    { "sbo map card on|off", "click a room: its [QUEST]/[SHOP] NPCs, enter commands, kills, loot, deaths" },
    { "sbo map find {text}", "find rooms by name; click a result to show it or walk there" },
    { "sbo map walk {room #}", "walk to a room" },
    { "sbo map show {room #}", "centre the map on a room" },
    { "sbo map stop", "cancel a walk" },
    { "sbo map load [file]", "load a map file (default: map/mm_map.dat)" },
  } },
  { key = "log", title = "Kills, loot and progress", rows = {
    { "sbo kills [all]", "what you've killed, with counts and exp (reset: this session, clear: all)" },
    { "sbo loot [text]", "what was picked up and the exact room; text searches it (all, clear)" },
    { "sbo session [reset]", "exp gained, exp/hour, time and kills to next level" },
  } },
  { key = "bar", title = "Prompt bar", rows = {
    { "sbo bar on|off", "your prompt as a bar of HP / SP / ST gauges under the text" },
    { "sbo bar gauges|raw", "gauges, or the prompt exactly as the game sends it" },
    { "sbo bar session on|off", "session time, kills/deaths and exp per hour on the bar" },
    { "sbo bar session full|short", "time · k/d · xp/hr, or just xp/hr" },
    { "sbo bar session top|bottom", "where that goes when it doesn't fit on the bar" },
    { "sbo bar width [n]", "length of each gauge (default 10)" },
    { "sbo bar lines [n]  /  font [n]", "bar height / font size" },
    { "sbo bar bg [r g b]", "background colour, 0-255 each" },
    { "sbo bar blanks on|off", "keep the blank line the game puts before each prompt" },
  } },
  { key = "window", title = "Windows and display", rows = {
    { "sbo on|off", "turn formatting on / off" },
    { "sbo main replace|keep", "formatted text in the main window, or leave the main window alone" },
    { "sbo window on|off", "the Inspector window (drag it by its title, resize from its edges)" },
    { "sbo helpwindow on|off", "game help pages (and this list) in their own window" },
    { "sbo font [size]", "Inspector / help window font size" },
    { "sbo clear", "clear the Inspector's history" },
  } },
  { key = "update", title = "Updates and troubleshooting", rows = {
    { "sbo update", "get the newest version, settings kept (or click the version on the bar)" },
    { "sbo update auto on|off", "install new versions by themselves" },
    { "sbo update force", "reinstall even if you're current" },
    { "sbo update {file}", "install a local .mpackage file" },
    { "sbo samples on|off", "log raw game output to oven_samples.txt (helps fix layouts)" },
    { "sbo prompt [pattern]", "set your prompt pattern (blank = detect it automatically)" },
  } },
}

function M.help(section)
  section = trim(section or ""):lower()
  local pick
  for _, s in ipairs(M.helpSections) do
    if section ~= "" and (s.key == section or s.title:lower():find(section, 1, true)) then pick = s; break end
  end
  local cmdW = 0
  for _, s in ipairs(M.helpSections) do
    for _, r in ipairs(s.rows) do cmdW = math.max(cmdW, ulen((r[1]:gsub("[{}]", "")))) end
  end
  local buf = {}
  local function add(a) buf[#buf + 1] = a end
  add("\n<orange>Soft Bun's Oven<reset> <dim_grey>v" .. M.version .. " by softbuns  ·  `oven` works as well as `sbo`<reset>\n")
  if section ~= "" and not pick then add("<dim_grey>no section called '" .. section .. "' - here's everything<reset>\n") end
  for _, s in ipairs(M.helpSections) do
    if not pick or pick == s then
      add("\n<turquoise>▸ " .. s.title .. "<reset>  <dim_grey>sbo help " .. s.key .. "<reset>\n")
      for _, r in ipairs(s.rows) do
        if r[1] == "" then add("\n")
        else
          -- {word} = something you fill in, shown as a grey word
          local shown = r[1]:gsub("{([^}]*)}", "%1")
          local cmd = r[1]:gsub("{([^}]*)}", "<light_slate_grey>%1<khaki>")
          add("  <khaki>" .. cmd .. "<reset>" .. string.rep(" ", cmdW - ulen(shown) + 3) .. r[2] .. "\n")
        end
      end
    end
  end
  add("\n<dim_grey>grey words: fill in your own  ·  [in brackets]: optional  ·  a|b: pick one  ·  a number left off = default<reset>\n")
  add(string.format("<dim_grey>now: formatting %s · main %s · Inspector %s · help window %s · bar %s · map %s<reset>\n",
    M.cfg.enabled and "on" or "off", M.cfg.main, M.cfg.window and "on" or "off", M.cfg.helpWindow and "on" or "off",
    M.cfg.bar and "on" or "off", M.cfg.map and "on" or "off"))
  local text = table.concat(buf)
  if M.cfg.helpWindow then
    local lines = {}
    for l in (text:gsub("^\n", "") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
    M.helpPage(pick and ("Soft Bun's Oven: " .. pick.title) or "Soft Bun's Oven", lines, "cecho")
    M.log("<dim_grey>[sbo] command list → help window<reset>")
  else
    M.log((text:gsub("^\n", ""):gsub("\n$", "")))
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
  elseif a == "learn" then return M.learn()
  elseif a == "loot" then
    if b == "clear" then M.cfg.loot = {}; M.saveSettings(); return say("loot log cleared") end
    local all = b == "all" or b:match("^all%s") ~= nil
    local q = all and b:gsub("^all%s*", "") or b
    local w = M.cfg.window and M.viewCols() or columns("main")
    local lines, links = M.lootLines(w, q, all)
    if M.cfg.window then M.viewAdd({ lines = lines, links = links }) else render("main", lines) end
    return
  elseif a == "kills" then
    if b == "reset" then M.sess.killBook = {}; return say("this session's kill list cleared")
    elseif b == "clear" then M.cfg.kills = {}; M.saveSettings(); return say("all-time kill list cleared") end
    local lines = M.killLines(M.cfg.window and M.viewCols() or columns("main"), b == "all")
    if M.cfg.window then M.viewAdd({ lines = lines, links = {} }) else render("main", lines) end
    return
  elseif a == "quest" or a == "quests" then
    local sub, val = b:match("^(%S*)%s*(.-)$")
    if sub == "pin" and val ~= "" then M.questPin(val, true); return say("pinned " .. val .. " to the quest tracker")
    elseif sub == "unpin" and val ~= "" then M.questPin(val, false); return say("unpinned " .. val)
    elseif sub == "refresh" then M.questRefresh(val ~= "" and val or "all"); return
    elseif sub == "hide" then
      if M.questHud then M.questHud:hide() end
      for _, c in ipairs(M.questCards or {}) do c:hide() end
      return
    elseif sub == "hud" and (val == "left" or val == "right") then
      M.cfg.questHudSide = val; M.cfg.questHudPos = nil; M.saveSettings(); M.drawQuestTracker(); return say("quest HUD on the " .. val)
    elseif sub == "hud" and val:match("^opacity") then
      local n = val:match("^opacity%s*(%d*)%%?$")
      if n == nil then return say("usage: sbo quest hud opacity <0-100>  (nothing = opaque)") end
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
    return say("usage: sbo quest pin|unpin <id|all>, sbo quest refresh [id], sbo quest show|hide")
  elseif a == "map" then
    if b == "on" then
      M.cfg.map = true; M.saveSettings(); M.mapStart()
      return say("map: following you by room number; double-click a room to walk there (sbo map stop cancels)")
    elseif b == "off" then
      M.cfg.map = false; M.saveSettings(); M.mapStop(); return say("map following and click-to-walk off")
    elseif b == "stop" then
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
      .. "  (sbo map on|off|stop|load [file])")
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
    M.log("<dim_grey>[sbo] " .. long .. "<reset>")
  end
end

-- a click on the bar: on the version tag (right end) = sbo update
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
  if M.mapHandler then killAnonymousEventHandler(M.mapHandler); M.mapHandler = nil end
  if M.mapHoverTimer then killTimer(M.mapHoverTimer); M.mapHoverTimer = nil end   -- (0.16.4's hover)
  if M.mapHoverTip then pcall(function() M.mapHoverTip:hide() end) end
  if M.mapSelTimer then killTimer(M.mapSelTimer); M.mapSelTimer = nil end
end

function M.init()
  M.updating = nil
  M.teardown()
  M.dropPages()
  M.loadSettings()
  M.quests = M.cfg.quests or M.quests or {}
  M.handlers = {
    registerAnonymousEventHandler("sysDataSendRequest", M.onSend),
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
  M.loadItems()
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysWindowResizeEvent", function() M.layoutBar(); pcall(M.drawBar); pcall(M.layoutQuestHud) end)
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysDownloadDone", M.onDownload)
  M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("sysDownloadError", M.onDownload)
  for _, v in ipairs({ "LEVEL", "EXPERIENCE", "EXPERIENCE_MAX", "EXPERIENCE_TNL", "EXPERIENCE_TO_LEVEL" }) do
    M.handlers[#M.handlers + 1] = registerAnonymousEventHandler("msdp." .. v, M.onMsdp)
  end
  M.lineTrigger = tempRegexTrigger("^", function() M.onLine() end)
  M.alias = tempAlias("^(?:sbo|oven)(?:\\s+(.*))?$", function() M.command(matches[2]) end)
  if M.cfg.window and M.container then M.container:show() end
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
