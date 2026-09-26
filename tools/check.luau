--!strict
-- Type checks every Luau file in the project. `lute run tools/check.luau`
local fs = require("@lute/fs")
local process = require("@lute/process")

local files = {}

local function walk(dir: string)
	for _, entry in fs.listdir(dir) do
		local name = entry.name
		local path = `{dir}/{name}`
		if entry.type == "dir" then
			walk(path)
		elseif string.match(name, "%.luau$") then
			table.insert(files, path)
		end
	end
end

for _, root in { "./src", "./examples", "./tests", "./tools" } do
	if fs.exists(root) then
		walk(root)
	end
end
table.sort(files)

local args = { process.execPath(), "check" }
for _, file in files do
	table.insert(args, file)
end

local result = process.run(args)
if result.stdout ~= "" then
	print(result.stdout)
end
if result.stderr ~= "" then
	print(result.stderr)
end
if result.ok and result.stdout == "" and result.stderr == "" then
	print(`clean: {#files} files typecheck`)
else
	process.exit(1)
end
