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
M.version = "0.2"
M.mod_date = "2013/10/16"
M.url_json = "http://glyphwiki.org/json?name=%s"
M.url_eps = "http://glyphwiki.org/glyph/%s@%d.eps"
M.epstopdf = "epstopdf"
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
    os.exit(-1)
  end
  function M.sure(value, arg1, ...)
    if value then return value end
    if type(arg1) == "number" then
      arg1 = "error("..arg1..")"
    end
    M.abort(arg1, ...)
  end
  function M.message(str)
    if M.wdir then
      local fname = M.ppfx..M.resp_file
      local hmsg = io.open(fname, "wb")
      if hmsg then
        local msg = "\\do{"..str.."}%\n"
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
  local http = require("socket.http")
  function M.http_get(url)
    --local cached = http_cache[url]
    --if cached then return cached end
    local resp, status = http.request(url)
    M.sure(resp and status == 200, "download failure")
    return resp
  end
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
        infoh:write(("\\rev{%s}{%s}%%\n"):format(r, info[r]))
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
---------------------------------------- glyph files
do
  function M.write_glyph(eps, fbase)
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
  function M.do_ping(id)
    M.sure(id, "id missing")
    M.message(id)
  end
  local dum = "\233\150\162\233\128\163\229\173\151"
  function M.do_info(glyph)
    local info = M.read_info(glyph)
    local json = M.http_get(M.url_json:format(glyph))
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
    local eps = M.http_get(M.url_eps:format(glyph, rev))
    M.write_glyph(eps, fbase)
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
---------------------------------------- bootstrap
if not M.internal then
-- bxglyphwiki +ping <wdir> <format> <driver> <id>
-- bxglyphwiki +info <wdir> <format> <driver> <glyph>
-- bxglyphwiki +get <wdir> <format> <driver> <glyph> <rev>
  local s, e, t = (arg[1] or ""):find("^%+(.+)")
  arg[1] = t or ""
  M.main((table.unpack or unpack)(arg))
end
---------------------------------------- done
--EOF
