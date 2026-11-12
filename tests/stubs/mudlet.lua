local out = {}
function getMudletHomeDir() return OVEN_TEST_HOME or "." end
io.exists = function(f) local h=io.open(f) if h then h:close() return true end return false end
table.save=function() end; table.load=function() end
timers={}; local tid=0
function tempTimer(t,f) tid=tid+1; timers[tid]={t,f}; return tid end
function killTimer(id) timers[id]=nil end
-- all of them, soonest first (then oldest), like time passing
function runTimers()
  while true do
    local best, bid
    for id, t in pairs(timers) do
      if not best or t[1] < best[1] or (t[1] == best[1] and id < bid) then best, bid = t, id end
    end
    if not best then return end
    timers[bid] = nil
    best[2]()
  end
end
function fg(w,c) end function resetFormat() end
function echo(w,t) if t==nil then t=w end io.write(t) end
function decho(w,t) if t==nil then t=w end io.write("[D]"..t) end
cecho=decho
function getWindowWrap() return 100 end function getColumnCount() return 130 end
-- several handlers per event, as in Mudlet: handlers[e](...) runs them all
HANDLER_LISTS = {}
function registerAnonymousEventHandler(e,f)
  handlers = handlers or {}
  HANDLER_LISTS[e] = HANDLER_LISTS[e] or {}
  table.insert(HANDLER_LISTS[e], f)
  handlers[e] = function(...) for _, h in ipairs(HANDLER_LISTS[e]) do h(...) end end
  return 1
end
function tempRegexTrigger(r,f) lineFn=f; return 1 end
function tempAlias(r,f) return 1 end
function moveCursorEnd() end function getCurrentLine() return "" end
function selectCurrentLine() end function deselect() end
function copy2decho() return line end
function deleteLine() io.write("  (gagged: "..line..")\n") end
function isPrompt() return promptFlag end
function debugc(s) print(s) end
Adjustable={Container={new=function() return {show=function() end,hide=function() end} end}}
Geyser={MiniConsole={new=function() return {} end}}
function echoLink(w,t,c,h) io.write("{LINK "..t.." -> "..c.."}") end
function getMainWindowSize() return 1600,900 end
function setBorderBottom(h) print("[setBorderBottom "..h.."]") end
function calcFontSize() return 8,16 end
function getBorderSizes() return {left=0,right=565,top=0,bottom=0} end
function getBorderRight() return 565 end
function clearWindow() end
Geyser={MiniConsole={new=function(self,o) local t={} function t:show() end function t:hide() end function t:move(x,y) print("[bar move",x,y,"]") end function t:resize(w,h) print("[bar resize",w,h,"]") end return t end}}
table.save=function(f,t) _G.__saved=t end
function getFont() return "Ubuntu Mono" end function setFont() end function getFontSize() return 14 end
function getPackages() return {"SoftbunsOS"} end table.contains=function(t,v) for _,x in ipairs(t) do if x==v then return true end end return false end function uninstallPackage(p) print("[uninstall "..p.."]") end function installPackage(p) print("[install "..p.."]") end
function killAnonymousEventHandler() end function killTrigger() end function killAlias() end
function scrollTo() end
_cecho_orig = cecho
function cecho(w,t) if t==nil then t=w; w="main" end io.write("["..w.."]"..t) end
function decho(w,t) if t==nil then t=w; w="main" end io.write("[D:"..w.."]"..t) end
Geyser.ScrollBox={new=function(self,o) local t={} function t:get_width() return 700 end return t end}
Geyser.Label={new=function(self,o) local t={name=o.name} function t:setStyleSheet() end
  function t:resize(w,h) print("[label resize "..tostring(h).."]") end
  function t:rawEcho(m) io.write("[LABEL]\n"..m.."\n[/LABEL]\n") end return t end}
function decho2html(s) return (s:gsub("<(%d+),(%d+),(%d+)>","<span c=%1>")) end
function cecho2html(s) return (s:gsub("<([%w_]+)>","{%1}")) end
color_table = {gold={255,215,0}, dim_grey={105,105,105}}
Adjustable.Container.new=function() return {show=function() end,hide=function() end} end
function send(c, e) print("[send "..c.." echo="..tostring(e).."]") end
-- a tiny fake main buffer for line-number based calls
BUF = {} CUR = 0
function getLineNumber() return CUR end
function getLines(a, b) local t = {} for i = a, b - 1 do t[#t+1] = BUF[i+1] end return t end
function moveCursor(x, y) CUR = y return true end
function moveCursorEnd() CUR = #BUF - 1 end
function deleteLine() if BUF[CUR+1] then table.remove(BUF, CUR+1) end end
function setFgColor(w,r,g,b) io.write("{"..r..","..g..","..b.."}") end
function downloadFile(p,u) print("[download "..u.."]") end
function setBackgroundColor(w,r,g,b,a) print("[bg "..w.." "..r..","..g..","..b.."]") end function setBgColor() end
function setBorderTop(h) BT=h end function getBorderTop() return BT or 0 end

CREATED, DELETED = {}, {}
Geyser.ScrollBox={new=function(self,o,container) local t={name=o.name} CREATED[#CREATED+1]=o.name .. (container and " (in window)" or " (ON MAIN SCREEN!)")
  function t:get_width() return 700 end function t:get_height() return 500 end function t:delete() DELETED[#DELETED+1]=t.name end return t end}
Geyser.Label={new=function(self,o) local t={name=o.name}
  function t:setStyleSheet(s) t.css=s end function t:setCursor() end function t:show() t.shown=true end function t:hide() t.shown=false end
  function t:resize(w,h) t.h=h end function t:move(x,y) t.y=y end
  function t:rawEcho(m) t.html=m end function t:echo(m) t.text=m end
  function t:setClickCallback(f) t.click=f end function t:getSizeHint() return 600,400 end
  function t:setMoveCallback(f) t.onMove=f end function t:setReleaseCallback(f) t.onRelease=f end
  function t:setToolTip() end function t:raise() end function t:get_x() return t.x0 or 0 end function t:get_y() return t.y0 or 0 end
  return t end}
function deleteScrollBox(n) DELETED[#DELETED+1]=n.."(by name)" end

-- Mudlet ships a utf8 library; plain Lua 5.1 doesn't. Minimal stand-in for tests.
if not utf8 then
  utf8 = {}
  function utf8.len(s) local _, n = s:gsub("[^\128-\191]", "") return n end
  function utf8.sub(s, i, j)
    local chars = {}
    for ch in s:gmatch("[%z\1-\127\194-\244][\128-\191]*") do chars[#chars + 1] = ch end
    local n = #chars
    i = i or 1; j = j or n
    if i < 0 then i = n + i + 1 end
    if j < 0 then j = n + j + 1 end
    if i < 1 then i = 1 end
    if j > n then j = n end
    if i > j then return "" end
    return table.concat(chars, "", i, j)
  end
  utf8.charpattern = "[%z\1-\127\194-\244][\128-\191]*"
end

-- layout widgets: remember who's hidden, so tests can see which tab is in front
local function box(kind)
  return { new = function(self, o, parent)
    local t = { name = o.name, kind = kind, parent = parent, shown = true }
    function t:show() t.shown = true end
    function t:hide() t.shown = false end
    function t:setStyleSheet(s) t.css = s end
    function t:echo(m) t.text = m end
    function t:setClickCallback(f) t.click = f end
    function t:setCursor() end
    function t:raise() end
    WIDGETS = WIDGETS or {}; WIDGETS[o.name] = t
    return t
  end }
end
Geyser.Container = box("container"); Geyser.VBox = box("vbox"); Geyser.HBox = box("hbox")
Geyser.Fixed, Geyser.Dynamic = "fixed", "dynamic"
local labelNew = Geyser.Label.new
Geyser.Label.new = function(self, o, parent) local t = labelNew(self, o, parent); WIDGETS = WIDGETS or {}; WIDGETS[o.name] = t; return t end

-- a mini console that keeps what's echoed into it
Geyser.MiniConsole = { new = function(self, o, parent)
  local t = { name = o.name, text = "", shown = true }
  function t:decho(s) t.text = t.text .. s end
  function t:clear() t.text = "" end
  function t:show() t.shown = true end function t:hide() t.shown = false end
  function t:setFont() end function t:setFontSize() end function t:enableAutoWrap() end function t:enableScrollBar() end
  function t:move() end function t:resize() end
  WIDGETS = WIDGETS or {}; WIDGETS[o.name] = t
  return t
end }
