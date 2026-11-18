-- The matcher of rex-thumbs: find the text to hint, and make the hints.
-- Pure Lua 5.1. Rex's Lua has no %f frontier pattern, so word boundaries
-- are checked by hand.
local M = {}

-- The "qwerty" alphabet of tmux-thumbs.
M.ALPHABET = "asdfqwerzxcvjklmiuopghtybn"

local hex = "%x"
local url_tail = "[^%s<>\"'`]+"

-- One pattern is a table:
--   pat    A Lua pattern. Two empty captures () select the part to copy.
--   token  An anchored pattern for one word ([%w_]+), in place of pat.
--   lit    Plain text that a match always holds. Lines without it are
--          skipped, which makes the scan fast.
--   word   The match must not touch a word character on either side.
--   after  The match must not touch a word character on its right.
--   min, max  Limits on the length of the copied text.
--   trim   Remove sentence punctuation from the end.
--   bol    The match must start in column 1.
--   ext, ext_n  A pattern that can follow the match, at most ext_n times.
--   ip     Each number has at most 3 digits.
-- In priority order: when two patterns start at the same column, the first
-- one wins.
M.PATTERNS = {
  { pat = "%[[^%]]*%]%(()[^%)%s]+()%)", lit = "](" },                  -- markdown link
  { pat = "https?://" .. url_tail, lit = "://", trim = true },          -- URL
  { pat = "git@" .. url_tail, lit = "git@", trim = true },
  { pat = "git://" .. url_tail, lit = "git://", trim = true },
  { pat = "ssh://" .. url_tail, lit = "ssh://", trim = true },
  { pat = "ftp://" .. url_tail, lit = "ftp://", trim = true },
  { pat = "file:///" .. url_tail, lit = "file:///", trim = true },
  { pat = "%-%-%- a/()%S+()", lit = "--- a/", bol = true },              -- diff a/
  { pat = "%+%+%+ b/()%S+()", lit = "+++ b/", bol = true },              -- diff b/
  { pat = "sha256:" .. hex:rep(64), lit = "sha256:", word = true },      -- docker
  { pat = hex:rep(8) .. "%-" .. hex:rep(4) .. "%-" .. hex:rep(4) .. "%-"
      .. hex:rep(4) .. "%-" .. hex:rep(12), lit = "-", word = true },    -- UUID
  { pat = "[%w_%.%-@~]*/[%w_%.%-@][%w_%.%-@/]*", lit = "/",
    ext = ":%d+", ext_n = 2, trim = true },                              -- path[:line[:col]]
  { pat = "#" .. hex:rep(6), lit = "#", after = true },                  -- color
  { pat = "%d+%.%d+%.%d+%.%d+", lit = ".", word = true, ip = true,
    ext = ":%d+", ext_n = 1 },                                           -- IPv4[:port]
  { token = "^0x%x+$" },                                                 -- address
  { token = "^[0-9a-f]+$", min = 7, max = 40 },                          -- git hash
  { token = "^[k-z]+$", min = 8, max = 32 },                             -- jj change ID
  { token = "^%d+$", min = 4 },                                          -- number
}

-- The patterns of the user, then the built-in ones. A string is a Lua
-- pattern. A table is a pattern as above.
function M.compile(extra)
  local out = {}
  for _, p in ipairs(extra or {}) do
    out[#out + 1] = type(p) == "string" and { pat = p } or p
  end
  for _, p in ipairs(M.PATTERNS) do out[#out + 1] = p end
  return out
end

local function is_word(line, i)
  return i >= 1 and i <= #line and line:sub(i, i):find("[%w_]") ~= nil
end

-- Remove the punctuation that ends a sentence, and a ')' with no '('.
function M.trim(text)
  text = text:gsub("[%.,;:!%?'\"]+$", "")
  while text:sub(-1) == ")" do
    local _, open = text:gsub("%(", "")
    local _, close = text:gsub("%)", "")
    if close <= open then break end
    text = text:sub(1, -2):gsub("[%.,;:!%?]+$", "")
  end
  return text
end

-- The next match of p at or after pos: the start and end of the whole
-- match, and the start and end of the part to copy. nil if there is none.
local function search(p, line, pos)
  while true do
    local s, e, a, b = line:find(p.pat, pos)
    if not s then return nil end
    local ok = not (p.bol and s ~= 1)
    if p.word and (is_word(line, s - 1) or is_word(line, e + 1)) then ok = false end
    if p.after and is_word(line, e + 1) then ok = false end
    if ok and p.ip then
      for octet in line:sub(s, e):gmatch("%d+") do
        if #octet > 3 then ok = false end
      end
    end
    local vs, ve = s, e
    if type(a) == "number" and type(b) == "number" then vs, ve = a, b - 1 end
    if ok and p.ext then
      for _ = 1, p.ext_n do
        local _, xe = line:find("^" .. p.ext, ve + 1)
        if not xe then break end
        ve, e = xe, xe
      end
    end
    local n = ve - vs + 1
    if ok and ((p.min and n < p.min) or (p.max and n > p.max)) then ok = false end
    if ok then return s, e, vs, ve end
    pos = e + 1
  end
end

-- The next word at or after pos that the token pattern accepts. A word is
-- a whole [%w_]+ run, so it has a word boundary on both sides. at[1] is a
-- cursor into words: pos only grows, so the scan never goes back.
local function search_token(p, line, words, pos, at)
  for k = at[1], #words do
    local w = words[k]
    if w[1] >= pos then
      at[1] = k
      local n = w[2] - w[1] + 1
      if not (p.min and n < p.min) and not (p.max and n > p.max)
        and line:sub(w[1], w[2]):find(p.token) then
        return w[1], w[2], w[1], w[2]
      end
    end
  end
  at[1] = #words + 1
end

-- The matches in one line, as { start, end } byte pairs, left to right.
function M.find(line, patterns)
  patterns = patterns or M.PATTERNS
  local found, pos, cache, cursor, words = {}, 1, {}, {}, nil
  for i, p in ipairs(patterns) do
    if p.lit and not line:find(p.lit, 1, true) then cache[i] = false end
  end
  while pos <= #line do
    local best
    for i, p in ipairs(patterns) do
      local c = cache[i]
      if c == nil or (c and c[1] < pos) then
        local s, e, vs, ve
        if p.token then
          if not words then
            words = {}
            for ws, we in line:gmatch("()[%w_]+()") do words[#words + 1] = { ws, we - 1 } end
          end
          cursor[i] = cursor[i] or { 1 }
          s, e, vs, ve = search_token(p, line, words, pos, cursor[i])
        else
          s, e, vs, ve = search(p, line, pos)
        end
        c = s and { s, e, vs, ve, p } or false
        cache[i] = c
      end
      if c and (best == nil or c[1] < best[1]) then best = c end
    end
    if not best then break end
    local vs, ve = best[3], best[4]
    if best[5].trim then ve = vs + #M.trim(line:sub(vs, ve)) - 1 end
    if ve >= vs then found[#found + 1] = { vs, ve } end
    pos = math.max(best[2] + 1, pos + 1)
  end
  return found
end

-- n hints. No hint is the start of another, and short hints come first.
function M.hints(n, alphabet)
  alphabet = alphabet or M.ALPHABET
  local out = {}
  if n <= #alphabet then
    for k = 1, n do out[k] = alphabet:sub(k, k) end
    return out
  end
  local keys, i = { "" }, 1
  while #keys - i + 1 < n do
    local prefix = keys[i]
    i = i + 1
    for k = 1, #alphabet do keys[#keys + 1] = prefix .. alphabet:sub(k, k) end
  end
  for k = i, i + n - 1 do out[#out + 1] = keys[k] end
  return out
end

-- The marks of a screen, as { row, start, end, text, hint } tables. Each
-- different text gets one hint. The lines near the bottom get the short
-- hints, because the newest output is there.
function M.assign(lines, patterns, alphabet)
  local marks, order, seen = {}, {}, {}
  for row = #lines, 1, -1 do
    for _, m in ipairs(M.find(lines[row], patterns)) do
      local text = lines[row]:sub(m[1], m[2])
      marks[#marks + 1] = { row, m[1], m[2], text }
      if not seen[text] then
        seen[text] = true
        order[#order + 1] = text
      end
    end
  end
  local keys, by_text = M.hints(#order, alphabet), {}
  for k, text in ipairs(order) do by_text[text] = keys[k] end
  for _, m in ipairs(marks) do m[5] = by_text[m[4]] end
  return marks
end

return M
