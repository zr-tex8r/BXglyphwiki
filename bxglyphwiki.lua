--#!/usr/bin/env lua
-- bxglyphwiki.lua

if bxglyphwiki then
  bxglyphwiki.internal = true
else
  bxglyphwiki = {}
end
local M = bxglyphwiki
---------------------------------------- interfaces
M.prog_name = "bxglyphwiki"
M.version = "0.5-pre"
M.mod_date = "2020/08/26"
M.url_json = "https://glyphwiki.org/json?name=%s"
M.url_svg = "https://glyphwiki.org/glyph/%s@%d.svg"
M.epstopdf = "repstopdf"
M.extractbb = "extractbb"
do
  M.prefix = "bxgw_"
  M.resp_file = "resp_.def"
  M.info_file = "%s.def"
  M.glyph_fbase = "%s_%d"
  function M.info(...)
    local t = { M.prog_name, ... }
    io.stderr:write(table.concat(t, ": ").."\n")
  end
  function M.abort(...)
    M.info(...)
    M.message("")
    if M.internal then error()
    else os.exit(-1)
    end
  end
  function M.sure(value, arg1, ...)
    if value then return value end
    if type(arg1) == "number" then
      arg1 = "error("..arg1..")"
    end
    M.abort(arg1, ...)
  end
  function M.message(str)
    if M.internal then
      M.msg = tostring(str)
    elseif M.wdir then
      local fname = M.ppfx..M.resp_file
      local hmsg = io.open(fname, "wb")
      if hmsg then
        local msg = "\\do{"..str.."}%\n"
        if msg:match("[\128-\255]") then
          msg = "\239\187\191"..msg -- prepend BOM
        end
        hmsg:write(msg)
        hmsg:close()
      else
        M.wdir = nil
        M.abort("cannot write to file", fname)
      end
    end
  end
end
---------------------------------------- misc
do
  local function div(a, b)
    return math.floor(a / b)
  end
  -- downloader
  function M.http_get(url, sal)
    local resp = zrget.download(url, nil, function(data)
      return data:sub(1, #sal) == sal
    end)
    M.sure(resp, "download failure")
    return resp
  end
  pcall(function()
    local https = require("ssl.https")
    M.info("'https' module available")
    -- make use of https if available
    function M.http_get(url)
      local resp, status = https.request(url)
      M.sure(resp and status == 200, "download failure")
      return resp
    end
  end)
  -- timestamp
  local MEP = 74223360
  local tmep = os.time({ year=2000, month=1, day=1, hour=0 })
  function M.timestamp(arg)
    return div(os.time(arg) - tmep, 60) + MEP
  end
  -- encoder
  function M.utf8(code)
    if code < 128 then return string.char(code) end
    local t, t1, t2, t3 = code
    t, t1 = div(t, 64), t % 64 + 128
    if t < 32 then return string.char(t + 192, t1) end
    t, t2 = div(t, 64), t % 64 + 128
    if t < 16 then return string.char(t + 224, t2, t1) end
    t, t3 = div(t, 64), t % 64 + 128
    M.sure(t < 8, "bad codepoint", code)
    return string.char(t + 240, t3, t2, t1)
  end
end
---------------------------------------- info files
do
  function M.read_tex(file)
    local texh = io.open(file, "rb")
    if not texh then return end
    local t = {}
    while true do
      local line = texh:read()
      if not line then break end
      table.insert(t, (line:gsub("%%.*", "")))
    end
    return table.concat(t, ""):gsub("%s+", "")
  end
  function M.read_info(glyph)
    local fname = M.ppfx..M.info_file:format(glyph)
    local text = M.read_tex(fname)
    if not text then return {} end
    local s, e, latest, u = text:find("^\\do{(%d+)}{(.*)}$")
    M.sure(u, "info syntax error")
    local t = { latest = latest }
    for rev, ts in u:gmatch("\\rev{(%d+)}{(%d+)}") do
      t[tonumber(rev)] = tonumber(ts)
    end
    return t
  end
  function M.write_info(glyph, info)
    local fname = M.ppfx..M.info_file:format(glyph)
    local infoh = io.open(fname, "wb")
    infoh:write(("\\do{%s}{%%\n"):format(info.latest))
    for r = info.latest, 1, -1 do
      if info[r] then 
        infoh:write(("\\rev{%d}{%d}%%\n"):format(r, info[r]))
      end
    end
    infoh:write("}%\n")
    infoh:close()
  end
end
---------------------------------------- json files
do
  function M.read_json(json)
    json = json:gsub("%s+", "")
    local rev, rel, _ = 0
    if not json:find('"version":null') then
      _, _, rev = json:find('"version":(%d+)')
      M.sure(rev, "json error")
    end
    _, _, rel = json:find('"related":"U%+(%w+)"')
    return tonumber(rev), (rel) and tonumber(rel, 16) or 0x3013
  end
end
---------------------------------------- svg-to-eps
do
  local prologue =
    '<svg xmlns="http://www.w3.org/2000/svg" '..
    'xmlns:xlink="http://www.w3.org/1999/xlink" version="1.1" '..
    'baseProfile="full" viewBox="0 0 200 200" width="200" '..
    'height="200"> <g fill="black"> '
  local epilogue =
    ' </g> </svg>'
  local function unenclose(str, pre, post)
    if str:sub(1, #pre) == pre and str:sub(-#post) == post then
      return str:sub(#pre + 1, -#post - 1)
    end
  end
  local function num(r)
    return ("%.4f"):format(r):gsub("0+$", ""):gsub("%.$", "")
  end
  local function eps_line(...)
    local t = {...}
    for i = 1, #t do
      t[i] = (type(t[i]) == "number") and num(t[i]) or tostring(t[i])
    end
    return table.concat(t, " ")
  end
  local function eps_line_xy(x, y, op)
    return eps_line(x * 5, 800 - y * 5, op)
  end
  local function parse_path(src)
    local op, ot, c = nil, nil, 0
    local v, epsls = {}, {}
    for w in src:gmatch("(%S+)") do
      if c > 0 then
        w = tonumber(w); v[c] = w; c = c - 1
        if not w then return end
      elseif w == "M" then
        op, ot, c = "moveto", "xy", 2
      elseif w == "L" then
        op, ot, c = "lineto", "xy", 2
      elseif w == "Z" then
        op, ot, c = "closepath", "", 0
      else return
      end
      if c == 0 then
        if ot == "xy" then
          w = eps_line_xy(v[2], v[1], op)
        else
          w = eps_line(op)
        end
        table.insert(epsls, w)
      end
    end
    return epsls
  end
  local function parse_polygon(src)
    src = src:gsub("> ", ">\n")
    local epsls = {}; local x, y, _
    for l in src:gmatch("([^\n]+)") do
      local a = unenclose(l, '<polygon points="', '" />')
      if not a then return end
      local op = "moveto"
      for w in a:gmatch("(%S+)") do
        _, _, x, y = w:find("^([-.%d]+),([-.%d]+)$")
        x, y = tonumber(x), tonumber(y)
        table.insert(epsls, eps_line_xy(x, y, op))
        op = "lineto"
      end
      table.insert(epsls, eps_line("closepath"))
      table.insert(epsls, eps_line("fill"))
    end
    return epsls
  end
  local function form_eps(epsls)
    local s = table.concat(epsls, "\n")
    return ([[
%!PS-Adobe-3.0 EPSF-3.0
%%BoundingBox: 0 -208 1024 816
%%EndComments
gsave
]]..s..[[

fill
grestore
%%EOF
]])
  end
  function M.svg_to_eps(svgsrc)
    local src = svgsrc:gsub("%s+", " "):gsub(" $", "")
    src = unenclose(src, prologue, epilogue)
    if not src then return end
    local t = unenclose(src, '<path d="', '" />')
    if t then -- SVG uses path elements
      t = parse_path(t)
    else      -- SVG uses polygon elements
      t = parse_polygon(src)
    end
    if t then
      return form_eps(t)
    end
  end
end
---------------------------------------- glyph files
do
  function M.write_glyph(svg, fbase)
    local eps = M.svg_to_eps(svg)
    M.sure(eps, "SVG->EPS conversion failure")
    local pbase = M.ppfx..fbase
    local epsh = io.open(pbase..".eps", "wb")
    M.sure(epsh, "cannot open for output", pbase..".eps")
    epsh:write(eps); epsh:close()
    if M.format == "pdf" then
      os.execute(M.epstopdf.." "..pbase..".eps")
      local pdfh = io.open(pbase..".pdf", "rb")
      M.sure(pdfh, "EPS->PDF conversion failure", pbase..".eps")
      pdfh:close()
      os.remove(pbase..".eps")
    end
  end
  function M.extract_bbox(fbase)
    local pbase = M.ppfx..fbase
    os.execute(M.extractbb.." "..pbase..".pdf")
    local xbbh = io.open(pbase..".xbb", "rb")
    M.sure(xbbh, "bbox extraction failure", pbase..".pdf")
    local bbox
    while true do
      local line = xbbh:read()
      if not line then break end
      local _, _, t = line:find("^%%%%BoundingBox:%s+(.*)")
      if t then bbox = t:gsub("%s+$", "") end
    end
    xbbh:close()
    os.remove(pbase..".xbb")
    return bbox
  end
end
---------------------------------------- core procedures
do
  if M.internal then
    function M.do_ping(id)
      M.sure(os.execute() > 0, "os.execute is disabled")
      M.message("OK")
    end
  else
    function M.do_ping(id)
      M.sure(id, "id missing")
      M.message(id)
    end
  end
  local dum = "\233\150\162\233\128\163\229\173\151"
  function M.do_info(glyph)
    local info = M.read_info(glyph)
    local json = M.http_get(M.url_json:format(glyph), '{')
    local latest, rel = M.read_json(json)
    if latest > 0 then
      info.latest = latest
      M.write_info(glyph, info)
    end
    M.message(("{%s}{%s}"):format(M.utf8(rel), dum))
  end
  function M.do_get(glyph, rev)
    rev = M.sure(tonumber(rev), "bad number format", rev)
    local info = M.read_info(glyph)
    local fbase = M.glyph_fbase:format(glyph, rev)
    local svg = M.http_get(M.url_svg:format(glyph, rev), '<svg')
    M.write_glyph(svg, fbase)
    info[rev] = M.timestamp()
    M.write_info(glyph, info)
    if M.use_bbox() then
      M.message(M.extract_bbox(fbase))
    else M.message("ok")
    end
  end
end
---------------------------------------- dispatcher
do
  M.dispatch = {
    ["ping"] = M.do_ping;
    ["info"] = M.do_info;
    ["get"] = M.do_get;
  }
  function M.main(cmd, wdir, fmt, drv, ...)
    M.sure(cmd ~= "" and wdir, "bad command syntax")
    M.wdir, M.format, M.driver = wdir, fmt, drv
    M.ppfx = M.wdir.."/"..M.prefix
    M.sure(fmt == "eps" or fmt == "pdf", "unknown format", fmt)
    local proc = M.sure(M.dispatch[cmd], "unknown command", cmd)
    proc(...)
  end
  function M.use_bbox()
    return (M.driver == "dvipdfmx" and M.format == "pdf")
  end
end
---------------------------------------- new downloader
--//////// 'zrget' module ////////
zrget = (function(M)
  -- parameters
  M.max_trial = M.max_trial  or 3
  M.interval  = M.interval   or 1 -- second
  M.log       = M.log        or true

  -- helpers
  local lfs = require 'lfs'
  local socket = require 'socket'
  local tempb = '__zrget'
  local win = (lfs.attributes('C:\\NUL', 'mode') ~= nil)
  local function upath(pth)
    return (win) and pth:gsub('\\', '/') or pth
  end
  local function npath(pth)
    return (win) and pth:gsub('/', '\\') or pth
  end
  local function log_print(s)
    io.stderr:write("zrget: ", s, "\n")
  end
  local function log(fmt, ...)
    if not M.log then return end
    local l = (type(M.log) == 'function') and M.log or log_print
    l(tostring(fmt):format(...))
  end
  local function file_ok(pth)
    return ((lfs.attributes(pth, 'size') or 0) > 0)
  end
  local function execute(clfmt, ...)
    local cl = clfmt:format(...)
    if M.verbose then log("RUN: %s", cl) end
    local ok = os.execute(cl)
    return (ok == true) or (ok == 0)
  end
  local function exefile(pth)
    pth = npath(pth..(win and '.exe' or ''))
    return (file_ok(pth) or nil) and pth
  end
  local function validate(vprc, pth)
    if not file_ok(pth) then return false end
    local h = io.open(pth, 'rb')
    local d = h and h:read('*a')
    if h then h:close() end
    local r = d and (not vprc or vprc(d))
    if not r then log("Validation failure") end
    return r and d
  end

  -- TeXLive stuffs
  local kpse
  pcall(function()
    kpse = require 'kpse'
    kpse.set_program_name('luatex')
  end)
  local tlpkg = kpse and kpse.var_value('SELFAUTOPARENT')
  tlpkg = tlpkg and tlpkg..'/tlpkg'
  local tlwget = tlpkg and exefile(tlpkg..'/installer/wget/wget')
  local tlperl = tlpkg and exefile(tlpkg..'/tlperl/bin/perl')

  -- methods
  local fcout, fcerr, ftdst =
      tempb..'-1.out', tempb..'-2.out', tempb..'-0.bin'
  local method_list = {
    {
      name = 'wget';
      checker = 'wget --version'; check_tag = 'Wget';
      loader = function(src)
        return execute('wget -q --no-check-certificate "%s" -O %s 2>%s',
            src, ftdst, fcerr)
      end
    },
    {
      name = 'curl';
      checker = 'curl --version'; check_tag = 'curl';
      loader = function(src)
        return execute('curl -k -s "%s" -o %s 2>%s',
            src, ftdst, fcerr)
      end
    },
    {
      name = 'tl-wget';
      checker = tlwget and tlwget..' --version'; check_tag = 'Wget';
      loader = function(src)
        return execute('%s -q --no-check-certificate "%s" -O %s 2>%s',
            tlwget, src, ftdst, fcerr)
      end
    },
    {
      name = 'powershell';
      checker = 'powershell -Help'; check_tag = 'PowerShell';
      loader = function(src)
        return execute('powershell -Command Invoke-WebRequest '..
            '"%s" -OutFile %s 2>%s',
            src, ftdst, fcerr)
      end
    },
    {
      name = 'tl-perl';
      checker = tlperl and tlperl..' --version'; check_tag = '?Perl';
      loader = function(src)
        return false -- TODO: make it
      end
    },
  }

  -- main procedure
  function M.download(url, dst, vprc)
    url = tostring(url):gsub('[\1-\31 \"\'<>\\`{|}]',
      function(s) return ('%%%02X'):format(string.byte(s)) end)
    if dst then
      if file_ok(dst) then
        log("File '%s' already exists", dst)
        return false
      end
      os.remove(dst)
    end
    --
    local data
    for tc = 1, M.max_trial do
      for _, mth in ipairs(method_list) do
        repeat
          if not mth.checker or mth.pass then break end
          log("Try method '%s'...(%s)", mth.name, tc)
          -- check
          execute('%s 1>%s 2>%s', mth.checker, fcout, fcerr)
          local hso = io.open(fcout, 'rb')
          local p = (hso and hso:read('*a') or ''):find(mth.check_tag, 1, true)
          hso:close()
          if not p then
            log("Method '%s' is not available", mth.name)
            mth.pass = true
            break
          end
          -- download
          log("Try downloading...")
          os.remove(ftdst)
          if mth.loader(url) then
            data = validate(vprc, ftdst)
            if data then break end
          end
          socket.sleep(M.interval)
          os.remove(ftdst)
        until true
        if data then break end
      end
      if data then break end
    end
    --
    local what = (dst) and ("File '%s'"):format(dst) or "Data"
    if data then
      if dst then os.rename(ftdst, dst) end
      log("%s is successfully downloaded", what)
    else
      log("%s cannot be downloaded", what)
    end
    --
    for _, f in ipairs {ftdst, fcerr, fcout} do
      os.remove(f)
    end
    return data
  end

  return M
end)({})
--////////////////////////////////
zrget.max_trial = 2
zrget.log = M.info
---------------------------------------- bootstrap
if M.internal then
  function M.spawn(argstr)
    local arg = (argstr or ""):explode()
    local ok = pcall(M.main, (table.unpack or unpack)(arg))
    if not ok then M.msg = "" end
    return (M.msg or "")
  end
else
-- bxglyphwiki +ping <wdir> <format> <driver> <id>
-- bxglyphwiki +info <wdir> <format> <driver> <glyph>
-- bxglyphwiki +get <wdir> <format> <driver> <glyph> <rev>
  local s, e, t = (arg[1] or ""):find("^%+(.+)")
  arg[1] = t or ""
  M.main((table.unpack or unpack)(arg))
end
---------------------------------------- done
--EOF
