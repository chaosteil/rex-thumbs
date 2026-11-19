-- Tests for matcher.lua. Run them in Rex's own Lua:
--   rex do test/matcher_test.lua
local here = debug.getinfo(1, "S").source:gsub("^@", "")
local root = here:match("^(.*)/test/[^/]*$") or "."
local M = dofile(root .. "/matcher.lua")

local failed, passed = 0, 0

local function texts(line, patterns)
  local out = {}
  for _, m in ipairs(M.find(line, patterns)) do out[#out + 1] = line:sub(m[1], m[2]) end
  return table.concat(out, " | ")
end

local function eq(name, got, want)
  if got == want then
    passed = passed + 1
  else
    failed = failed + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(name, tostring(got), tostring(want)))
  end
end

eq("URL drops sentence punctuation",
  texts("see https://example.com/a?b=(1). ok"), "https://example.com/a?b=(1)")
eq("markdown link gives the URL",
  texts("[docs](https://x.io/y), more"), "https://x.io/y")
eq("path with line and column",
  texts("at src/foo.rs:12:3 here"), "src/foo.rs:12:3")
eq("home path", texts("cd ~/code/x now"), "~/code/x")
eq("diff header gives the path", texts("+++ b/rex/init.lua"), "rex/init.lua")
eq("diff header only in column 1", texts("x +++ b/rex/init.lua"), "b/rex/init.lua")
eq("hash, jj change ID, UUID",
  texts("commit 5c56335e change tmspluvukply uuid 01a1f098-ddef-7799-b7ff-bcefc52ef5b1"),
  "5c56335e | tmspluvukply | 01a1f098-ddef-7799-b7ff-bcefc52ef5b1")
eq("IP, color, address, number",
  texts("ip 10.0.0.1:8080 color #ff00aa addr 0xdeadBEEF num 20000 and 123"),
  "10.0.0.1:8080 | #ff00aa | 0xdeadBEEF | 20000")
eq("docker digest", texts("sha256:" .. ("a"):rep(64)), "sha256:" .. ("a"):rep(64))
eq("no hash inside a word", texts("x_deadbeef1 deadbeefz"), "")
eq("IP with a long number is no IP", texts("1.2.3.4567"), "4567")
eq("plain words have no match", texts("plain words here with nothing"), "")
eq("user pattern wins a tie",
  texts("fix JIRA-1234 now", M.compile({ "JIRA%-%d+" })), "JIRA-1234")
eq("user pattern with a selected part",
  texts("see PR #42 ok", M.compile({ "PR #()%d+()" })), "42")

eq("single letters when they are enough", table.concat(M.hints(3), ","), "a,s,d")
local keys, unique, prefix = M.hints(700), {}, false
for _, a in ipairs(keys) do
  unique[a] = true
  for _, b in ipairs(keys) do
    if a ~= b and b:sub(1, #a) == a then prefix = true end
  end
end
local n = 0
for _ in pairs(unique) do n = n + 1 end
eq("700 unique hints", n, 700)
eq("no hint is the start of another", prefix, false)

local marks = M.assign({ "/a/b and /c/d", "/a/b" })
local by_text = {}
for _, m in ipairs(marks) do by_text[m[4]] = m[5] end
eq("same text same hint, bottom first", by_text["/a/b"] .. by_text["/c/d"], "as")
eq("one mark for each match", #marks, 3)

-- A path that wraps from row 2 to row 3, in a 10-column screen.
local rows = { "ok /a/b", "see src/ve", "ry/long.rs", " done" }
local groups = M.join(rows, { "old", "ok /a/b", "see src/very/long.rs done" })
eq("one group for each line", #groups, 2)
eq("wrapped rows join", table.concat(groups[2].rows, ","), "2,3,4")
eq("where each row starts", table.concat(groups[2].at, ","), "1,11,21")

local texts_of = {}
for k, g in ipairs(groups) do texts_of[k] = g.text end
marks = M.assign(texts_of)
local wrapped
for _, m in ipairs(marks) do
  if m[1] == 2 then wrapped = m end
end
eq("a match that wraps copies all of its text", wrapped[4], "src/very/long.rs")
local parts = {}
for _, p in ipairs(M.spans(groups, { wrapped })) do
  parts[#parts + 1] = ("%d:%d-%d:%s"):format(p[1], p[2], p[3], tostring(p[5]))
end
eq("a match that wraps shows on each row", table.concat(parts, " "), "2:5-10:true 3:1-10:false")

-- The start of the line is above the screen.
groups = M.join({ "ng.rs done", "x" }, { "see src/very/long.rs done", "x" })
eq("a line cut at the top", groups[1].at[1], 16)
marks = M.assign({ groups[1].text, groups[2].text }, nil, nil, { groups[1].at[1], 1 })
eq("a cut match copies all of its text", marks[1] and marks[1][4], "src/very/long.rs")
parts = {}
for _, p in ipairs(M.spans(groups, marks)) do
  parts[#parts + 1] = ("%d:%d-%d:%s"):format(p[1], p[2], p[3], tostring(p[5]))
end
eq("a cut match has its hint on the screen", table.concat(parts, " "), "1:1-5:true")
marks = M.assign({ "/a/b see", "x" }, nil, nil, { 6, 1 })
eq("no mark for a match above the screen", #marks, 0)

groups = M.join({ "a", "b" }, { "a", "c" })
eq("rows that do not agree stay one group each", #groups .. groups[2].text, "2b")

print(("%d passed, %d failed"):format(passed, failed))
if failed > 0 then rex.stop(1) end
