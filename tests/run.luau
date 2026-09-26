--!strict
-- Runs every *.test.luau in tests/. `lute run tests/run.luau`
local fs = require("@lute/fs")
local process = require("@lute/process")

local names = {}
for _, entry in fs.listdir("./tests") do
	if string.match(entry.name, "%.test%.luau$") then
		table.insert(names, entry.name)
	end
end
table.sort(names)

local failed = {}
for _, name in names do
	print(`\n=== {name} ===`)
	local result = process.run({ process.execPath(), "run", `./tests/{name}` })
	print((string.gsub(result.stdout, "\n$", "")))
	if result.stderr ~= "" then
		print(result.stderr)
	end
	if not result.ok or string.find(result.stdout, "FAILURES") ~= nil then
		table.insert(failed, name)
	end
end

print("\n" .. string.rep("-", 50))
if #failed == 0 then
	print(`ALL {#names} SUITES PASS`)
else
	print(`FAILED: {table.concat(failed, ", ")}`)
	process.exit(1)
end
