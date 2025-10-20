-- plugin/gcc1plus.lua
-- GCC Development Plugin for Neovim
-- Provides commands for debugging and testing GCC compiler changes

if vim.g.loaded_gcc_dev then
	return
end
vim.g.loaded_gcc_dev = 1

-- Get the GCC build root directory by walking up from current directory
local function get_gcc_root()
	local check_dir = vim.fn.getcwd()

	while check_dir ~= "/" do
		-- Check if this looks like a GCC root (has both gcc/ and build/ subdirs)
		local gcc_dir = check_dir .. "/gcc"
		local build_dir = check_dir .. "/build"
		if vim.fn.isdirectory(gcc_dir) == 1 and vim.fn.isdirectory(build_dir) == 1 then
			return check_dir
		end
		-- Go up one level
		check_dir = vim.fn.fnamemodify(check_dir, ":h")
	end

	return nil
end

-- Detect the target architecture directory in the build tree
local function get_target_arch(gcc_root)
	local build_dir = gcc_root .. "/build"

	-- Common target triplets to check for
	local common_targets = {
		"x86_64-pc-linux-gnu",
		"x86_64-linux-gnu",
		"aarch64-linux-gnu",
		"arm-linux-gnueabihf",
		"powerpc64le-linux-gnu",
		"riscv64-linux-gnu",
		"s390x-linux-gnu",
		"i686-pc-linux-gnu",
		"i686-linux-gnu",
	}

	-- First, try to find any directory that contains libstdc++-v3
	for _, target in ipairs(common_targets) do
		local target_path = build_dir .. "/" .. target
		local libstdcxx_path = target_path .. "/libstdc++-v3"
		if vim.fn.isdirectory(libstdcxx_path) == 1 then
			return target
		end
	end

	-- If no common target found, search for any directory with libstdc++-v3
	local find_cmd = string.format("find %s -maxdepth 2 -type d -name 'libstdc++-v3' 2>/dev/null", build_dir)
	local handle = io.popen(find_cmd)
	local result = handle:read("*l")
	handle:close()

	if result then
		-- Extract the parent directory name (the target triplet)
		local target = result:match(build_dir .. "/([^/]+)/libstdc%+%+%-v3")
		if target then
			return target
		end
	end

	return nil
end

-- Validate GCC environment and show helpful error
local function validate_gcc_env()
	local gcc_root = get_gcc_root()
	if not gcc_root then
		vim.notify(
			"Could not find GCC root directory.\n"
				.. "Please open Neovim from within your GCC source tree (anywhere inside gcc-trunk/ or gcc-source/, etc).\n"
				.. "The GCC root should contain both gcc/ and build/ directories.",
			vim.log.levels.ERROR
		)
		return nil, nil
	end

	-- Check if build directory exists and has been built
	local build_gcc = gcc_root .. "/build/gcc"
	local xgpp = build_gcc .. "/xg++"
	if vim.fn.executable(xgpp) ~= 1 then
		vim.notify(
			"GCC build not found or incomplete.\n"
				.. "Expected xg++ at: "
				.. xgpp
				.. "\n"
				.. 'Please run "make" in your build directory first.',
			vim.log.levels.ERROR
		)
		return nil, nil
	end

	-- Detect target architecture
	local target_arch = get_target_arch(gcc_root)
	if not target_arch then
		vim.notify(
			"Could not detect target architecture.\n"
				.. "Expected to find libstdc++-v3 in build/<target-triplet>/ directory.\n"
				.. "Please ensure libstdc++ has been built.",
			vim.log.levels.ERROR
		)
		return nil, nil
	end

	return gcc_root, target_arch
end

-- Parse DejaGNU directives from test file
local function parse_dejagnu_options(test_file)
	local file = io.open(test_file, "r")
	if not file then
		return ""
	end

	local options = {}
	local in_comment_block = false

	for line in file:lines() do
		-- Handle C++ style comments
		local comment = line:match("^%s*//(.*)$")
		if comment then
			-- Look for dg-options
			local dg_options = comment:match('{ dg%-options "([^"]*)" }') or comment:match("{ dg%-options '([^']*)' }")
			if dg_options then
				table.insert(options, dg_options)
			end

			-- Look for dg-additional-options
			local dg_additional = comment:match('{ dg%-additional%-options "([^"]*)" }')
				or comment:match("{ dg%-additional%-options '([^']*)' }")
			if dg_additional then
				table.insert(options, dg_additional)
			end

			-- Look for std= requirements
			local std_req = comment:match("{ dg%-require%-effective%-target c%+%+(%d+)") or comment:match("c%+%+(%d+)")
			if std_req and not line:match("dg%-options") then
				-- Only add if not already in dg-options
				local has_std = false
				for _, opt in ipairs(options) do
					if opt:match("-std=") then
						has_std = true
						break
					end
				end
				if not has_std then
					table.insert(options, "-std=c++" .. std_req)
				end
			end
		end

		-- Handle C style comment blocks
		if line:match("/%*") then
			in_comment_block = true
		end
		if in_comment_block then
			local dg_options = line:match('{ dg%-options "([^"]*)" }')
			if dg_options then
				table.insert(options, dg_options)
			end
		end
		if line:match("%*/") then
			in_comment_block = false
		end

		-- Stop after first 50 lines (directives are usually at the top)
		if #options > 0 and file:seek() > 2000 then
			break
		end
	end

	file:close()
	return table.concat(options, " ")
end

-- Helper function to extract cc1plus command from xg++ -v output
local function get_cc1plus_command(test_file, extra_args)
	extra_args = extra_args or ""

	-- Parse DejaGNU options from the test file
	local dejagnu_opts = parse_dejagnu_options(test_file)
	if dejagnu_opts ~= "" then
		vim.notify("Parsed test options: " .. dejagnu_opts, vim.log.levels.INFO)
		extra_args = dejagnu_opts .. " " .. extra_args
	end

	local gcc_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return nil
	end

	local libstdcxx_build = gcc_root .. "/build/" .. target_arch .. "/libstdc++-v3"
	local libstdcxx_source = gcc_root .. "/libstdc++-v3"
	local xgpp_path = gcc_root .. "/build/gcc/xg++"
	local gcc_build = gcc_root .. "/build/gcc"

	local xgpp_cmd = string.format(
		"%s -B%s -nostdinc++ "
			.. "-I%s/include/%s "
			.. "-I%s/include "
			.. "-I%s/libsupc++ "
			.. "-I%s/include/backward "
			.. "-I%s/testsuite/util "
			.. "%s -v %s 2>&1",
		xgpp_path,
		gcc_build,
		libstdcxx_build,
		target_arch,
		libstdcxx_build,
		libstdcxx_source,
		libstdcxx_source,
		libstdcxx_source,
		extra_args,
		test_file
	)

	local handle = io.popen(xgpp_cmd)
	local output = handle:read("*a")
	handle:close()

	-- Extract the cc1plus invocation from -v output
	for line in output:gmatch("[^\r\n]+") do
		if line:match("cc1plus") or line:match("cc1") then
			local cc1plus_cmd = line:match("^%s*(.-)%s*$") -- trim whitespace
			return cc1plus_cmd
		end
	end

	return nil
end

-- Help command
vim.api.nvim_create_user_command("GccHelp", function()
	local help_text = [[
GCC Development Plugin for Neovim
==================================

This plugin streamlines GCC C++ compiler development by providing commands to
debug, test, and navigate the GCC testsuite directly from Neovim.

QUICK START:
-----------
1. Open Neovim from anywhere in your GCC source tree
2. Run :GccCheck to verify your environment
3. Use :FindTest to search for tests
4. Press 'd' on a test to debug it with GDB

COMMANDS:
---------

:FindTest <pattern>
    Search for test files matching a pattern in the testsuite.
    Opens results in a split window with helpful keybindings.
    
    Keybindings in results window:
      <CR> - Open the test file for editing
      d    - Debug with GDB (runs :GdbCC1plus)
      r    - Compile test (runs :RunTest)
      t    - Run via testsuite (runs :RunTestsuite)
      l    - Show test log (g++.log)
      q    - Close the results window
    
    Examples:
      :FindTest constexpr     " Find all constexpr tests
      :FindTest cpp26/const   " Find all C++26 tests with const 
      :FindTest template      " Find template-related tests

:GdbCC1plus <test_file> [flags]
    Debug a test file with GDB. Automatically extracts the cc1plus command
    from xg++ including all the right include paths and flags.
    
    Examples:
      :GdbCC1plus gcc/testsuite/g++.dg/cpp26/constexpr-virt1.C
      :GdbCC1plus gcc/testsuite/g++.dg/cpp26/test.C -O2 -g

:RunTest <test_file>
    Quickly compile a test file using xg++ with proper libstdc++ paths.
    Automatically parses DejaGNU directives (dg-options, dg-additional-options).
    Opens compilation result in a terminal window.
    
    Examples:
      :RunTest gcc/testsuite/g++.dg/template/crash1.C
      :RunTest gcc/testsuite/g++.dg/cpp2a/concepts-fn1.C

:RunTestsuite <test_file>
    Run the full DejaGNU testsuite for a specific test via 'make check-g++'.
    This is the "official" way to run tests and see PASS/FAIL results.
    Results are logged to build/gcc/testsuite/g++/g++.log
    
    Example:
      :RunTestsuite gcc/testsuite/g++.dg/cpp26/constexpr-virt1.C

:ShowTestOptions <test_file>
    Display DejaGNU directives found in a test file (dg-options, etc.).
    Useful for understanding what flags a test expects.
    
    Example:
      :ShowTestOptions gcc/testsuite/g++.dg/cpp26/constexpr-virt1.C

:ShowTestLog
    Display the g++.log file from the last testsuite run.
    Shows PASS/FAIL results and any compiler output.
    Press 'q' to close the log viewer.

:GccCheck
    Verify your GCC environment is set up correctly.
    Checks for xg++, cc1plus, libstdc++ paths, etc.
    Also displays the detected target architecture.

SETUP REQUIREMENTS:
------------------
- GCC source tree with gcc/ directory
- build/ directory at same level as gcc/
- Compiled xg++ and cc1plus in build/gcc/
- libstdc++-v3 built in build/<target-triplet>/

The plugin will auto-detect your GCC root and target architecture by walking
up from your current directory. No manual configuration needed!

Supported architectures: x86_64, aarch64, arm, powerpc64le, riscv64, s390x, i686

TROUBLESHOOTING:
---------------
- "GCC root not found": Open Neovim from inside your GCC source tree
- "xg++ not found": Run 'make' in your build directory
- "Target architecture not detected": Ensure libstdc++ is built
- "No tests found": Check your search pattern or testsuite path

For more info or to report issues:
https://github.com/riogu/gcc1plus
]]

	local buf = vim.api.nvim_create_buf(false, true)
	local lines = vim.split(help_text, "\n")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "markdown")

	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":q<CR>", { noremap = true, silent = true })

	vim.notify("Press q to close help", vim.log.levels.INFO)
end, { nargs = 0 })

-- Environment check command
vim.api.nvim_create_user_command("GccCheck", function()
	local gcc_root = get_gcc_root()

	if not gcc_root then
		vim.notify(
			"✗ GCC root not found.\n" .. "Please open Neovim from within your GCC source tree.",
			vim.log.levels.ERROR
		)
		return
	end

	local target_arch = get_target_arch(gcc_root)

	local checks = {
		{ path = gcc_root .. "/gcc", desc = "GCC source directory" },
		{ path = gcc_root .. "/build", desc = "Build directory" },
		{ path = gcc_root .. "/build/gcc/xg++", desc = "xg++ compiler", executable = true },
		{ path = gcc_root .. "/build/gcc/cc1plus", desc = "cc1plus binary", executable = true },
		{
			path = target_arch and (gcc_root .. "/build/" .. target_arch .. "/libstdc++-v3") or "",
			desc = "libstdc++ build",
		},
		{ path = gcc_root .. "/libstdc++-v3", desc = "libstdc++ source" },
	}

	local all_ok = true
	local results = {
		"GCC Environment Check",
		"===================",
		"",
		"GCC Root: " .. gcc_root,
		"Target:   " .. (target_arch or "NOT DETECTED"),
		"",
	}

	for _, check in ipairs(checks) do
		if check.path == "" then
			table.insert(results, "✗ " .. check.desc .. " (architecture not detected)")
			all_ok = false
		else
			local ok = false
			if check.executable then
				ok = vim.fn.executable(check.path) == 1
			else
				ok = vim.fn.isdirectory(check.path) == 1 or vim.fn.filereadable(check.path) == 1
			end

			if ok then
				table.insert(results, "✓ " .. check.desc)
			else
				table.insert(results, "✗ " .. check.desc .. " (not found: " .. check.path .. ")")
				all_ok = false
			end
		end
	end

	table.insert(results, "")
	if all_ok then
		table.insert(results, "✓ All checks passed! GCC is correctly built and configured.")
	else
		table.insert(results, '✗ Some checks failed. You may need to run "make" in your build directory.')
	end

	vim.notify(table.concat(results, "\n"), all_ok and vim.log.levels.INFO or vim.log.levels.WARN)
end, { nargs = 0 })

-- Debug cc1plus with GDB
vim.api.nvim_create_user_command("GdbCC1plus", function(opts)
	local args = vim.split(opts.args, "%s+")
	if #args < 1 then
		vim.notify("Usage: :GdbCC1plus <test_file> [extra_flags]", vim.log.levels.ERROR)
		return
	end

	local test_file = args[1]
	local extra_args = #args > 1 and table.concat(vim.list_slice(args, 2), " ") or ""

	local gcc_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	vim.notify("Extracting cc1plus command...", vim.log.levels.INFO)
	local cc1plus_cmd = get_cc1plus_command(test_file, extra_args)

	if cc1plus_cmd then
		local gcc_build = gcc_root .. "/build/gcc"
		vim.notify("Starting GDB session for: " .. vim.fn.fnamemodify(test_file, ":t"), vim.log.levels.INFO)

		local buftype = vim.api.nvim_buf_get_option(0, "buftype")
		if buftype == "nofile" or buftype == "terminal" then
			vim.cmd("enew")
		end

		vim.cmd(string.format("GdbStart gdb -cd=%s -x .gdbinit --args %s", gcc_build, cc1plus_cmd))
	else
		vim.notify("Failed to extract cc1plus command. Check if xg++ can compile the test.", vim.log.levels.ERROR)
	end
end, { nargs = "+", complete = "file" })

-- Show DejaGNU directives
vim.api.nvim_create_user_command("ShowTestOptions", function(opts)
	if opts.args == "" then
		vim.notify("Usage: :ShowTestOptions <test_file>", vim.log.levels.ERROR)
		return
	end

	local test_file = opts.args
	local dejagnu_opts = parse_dejagnu_options(test_file)

	if dejagnu_opts ~= "" then
		vim.notify("DejaGNU options found: " .. dejagnu_opts, vim.log.levels.INFO)
	else
		vim.notify("No DejaGNU options found in: " .. vim.fn.fnamemodify(test_file, ":t"), vim.log.levels.WARN)
	end
end, { nargs = 1, complete = "file" })

-- Run test via full testsuite
vim.api.nvim_create_user_command("RunTestsuite", function(opts)
	if opts.args == "" then
		vim.notify("Usage: :RunTestsuite <test_file>", vim.log.levels.ERROR)
		return
	end

	local test_file = opts.args
	local filename = test_file:match("([^/]+)$")

	if not filename then
		vim.notify("Invalid test file path", vim.log.levels.ERROR)
		return
	end

	local gcc_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local build_root = gcc_root .. "/build/gcc"
	local cmd = string.format('cd %s && make check-g++ RUNTESTFLAGS="dg.exp=%s"', build_root, filename)

	vim.cmd("terminal " .. cmd)
end, { nargs = 1, complete = "file" })

-- Show test log
vim.api.nvim_create_user_command("ShowTestLog", function()
	local gcc_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local log_patterns = {
		gcc_root .. "/build/gcc/testsuite/g++/g++.log",
		gcc_root .. "/build/gcc/testsuite/g++.log",
	}

	local log_file = nil
	for _, pattern in ipairs(log_patterns) do
		if vim.fn.filereadable(pattern) == 1 then
			log_file = pattern
			break
		end
	end

	if not log_file then
		vim.notify("Test log not found. Run :RunTestsuite first to generate logs.", vim.log.levels.WARN)
		return
	end

	local handle = io.popen("cat " .. log_file)
	local output = handle:read("*a")
	handle:close()

	local buf = vim.api.nvim_create_buf(false, true)
	local lines = vim.split(output, "\n")
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "modifiable", false)
	vim.api.nvim_buf_set_option(buf, "filetype", "log")

	vim.api.nvim_win_set_buf(0, buf)
	vim.api.nvim_buf_set_keymap(buf, "n", "q", ":q<CR>", { noremap = true, silent = true })
	vim.notify("Showing test log (press q to close)", vim.log.levels.INFO)
end, { nargs = 0 })

-- Run test quickly
vim.api.nvim_create_user_command("RunTest", function(opts)
	if opts.args == "" then
		vim.notify("Usage: :RunTest <test_file>", vim.log.levels.ERROR)
		return
	end

	local test_file = opts.args
	local gcc_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local dejagnu_opts = parse_dejagnu_options(test_file)
	local libstdcxx_build = gcc_root .. "/build/" .. target_arch .. "/libstdc++-v3"
	local libstdcxx_source = gcc_root .. "/libstdc++-v3"
	local xgpp_path = gcc_root .. "/build/gcc/xg++"
	local gcc_build = gcc_root .. "/build/gcc"
	local abs_test_file = vim.fn.fnamemodify(test_file, ":p")

	local cmd = string.format(
		"cd %s && %s -B%s -nostdinc++ "
			.. "-I%s/include/%s "
			.. "-I%s/include "
			.. "-I%s/libsupc++ "
			.. "-I%s/include/backward "
			.. "-I%s/testsuite/util "
			.. "%s %s",
		gcc_build,
		xgpp_path,
		gcc_build,
		libstdcxx_build,
		target_arch,
		libstdcxx_build,
		libstdcxx_source,
		libstdcxx_source,
		libstdcxx_source,
		dejagnu_opts,
		abs_test_file
	)

	local test_name = vim.fn.fnamemodify(test_file, ":t")
	vim.notify(
		"Compiling: " .. test_name .. (dejagnu_opts ~= "" and " (with options: " .. dejagnu_opts .. ")" or ""),
		vim.log.levels.INFO
	)
	vim.cmd("terminal " .. cmd)
end, { nargs = 1, complete = "file" })

-- Search for tests
vim.api.nvim_create_user_command("FindTest", function(opts)
	if opts.args == "" then
		vim.notify("Usage: :FindTest <pattern>", vim.log.levels.ERROR)
		return
	end

	local pattern = opts.args
	local gcc_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local testsuite_path = gcc_root .. "/gcc/testsuite/g++.dg"
	local find_cmd = string.format("find %s -path '*%s*.C' -o -path '*%s*.cc'", testsuite_path, pattern, pattern)

	vim.notify("Searching for tests matching: " .. pattern, vim.log.levels.INFO)

	local handle = io.popen(find_cmd)
	local results = handle:read("*a")
	handle:close()

	local lines = {}
	for line in results:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	if #lines == 0 then
		vim.notify("No tests found matching: " .. pattern, vim.log.levels.WARN)
		return
	end

	-- Create a unique buffer without trying to set a name
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
	vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
	vim.api.nvim_buf_set_option(buf, "modifiable", false)

	vim.cmd("split")
	vim.api.nvim_win_set_buf(0, buf)

	local function get_current_path()
		local line = vim.api.nvim_get_current_line()
		return vim.fn.fnameescape(line)
	end

	-- Keybindings for test results
	local keymaps = {
		{ key = "<CR>", cmd = "edit", desc = "Open test file" },
		{ key = "d", cmd = "GdbCC1plus", desc = "Debug with GDB" },
		{ key = "r", cmd = "RunTest", desc = "Compile test" },
		{ key = "t", cmd = "RunTestsuite", desc = "Run via testsuite" },
		{ key = "l", cmd = "ShowTestLog", desc = "Show test log", no_arg = true },
		{ key = "q", cmd = "q", desc = "Close window", no_arg = true, direct = true },
	}

	for _, map in ipairs(keymaps) do
		vim.api.nvim_buf_set_keymap(buf, "n", map.key, "", {
			noremap = true,
			silent = true,
			desc = map.desc,
			callback = function()
				if map.direct then
					vim.cmd(map.cmd)
				elseif map.no_arg then
					vim.cmd("wincmd p")
					vim.cmd(map.cmd)
				else
					local path = get_current_path()
					vim.cmd("wincmd p")
					vim.cmd(map.cmd .. " " .. path)
				end
			end,
		})
	end

	vim.notify(
		string.format("Found %d tests. Use: <CR>=open | d=debug | r=compile | t=testsuite | l=log | q=quit", #lines),
		vim.log.levels.INFO
	)
end, { nargs = 1 })

-- Show welcome message on first load
vim.notify("GCC Dev Plugin loaded. Type :GccHelp for usage info.", vim.log.levels.INFO)
