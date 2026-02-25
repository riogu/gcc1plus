-- plugin/gcc1plus.lua
-- GCC Development Plugin for Neovim
-- Provides commands for debugging and testing GCC compiler changes
-- Supports multiple frontends: C++ (default) and Rust (gccrs)

if vim.g.loaded_gcc_dev then
	return
end
vim.g.loaded_gcc_dev = 1

-- =============================================================================
-- Frontend configurations
-- =============================================================================

local frontends = {
	cpp = {
		name = "C++",
		driver = "xg++",
		frontend_binary = "cc1plus",
		testsuite_subdir = "g++.dg",
		test_extensions = { "C", "cc" },
		check_target = "check-g++",
		log_patterns = {
			"gcc/testsuite/g++/g++.log",
			"gcc/testsuite/g++.log",
		},
		needs_libstdcxx = true,
		runtestflags_fmt = "dg.exp=%s",
		verbose_flag = "-v",
	},
	rust = {
		name = "Rust (gccrs)",
		driver = "gccrs",
		frontend_binary = "crab1",
		testsuite_subdir = "rust",
		test_extensions = { "rs" },
		check_target = "check-rust",
		log_patterns = {
			"gcc/testsuite/rust/rust.log",
			"gcc/testsuite/rust.log",
		},
		needs_libstdcxx = false,
		-- For gccrs, the exp file is inferred from the test's parent directory
		-- e.g. rust/compile/foo.rs -> compile.exp=foo.rs
		-- Fallback to compile.exp if we can't detect
		runtestflags_fmt = nil, -- uses get_runtestflags() instead
		-- gccrs uses --verbose instead of -v
		verbose_flag = "--verbose",
	},
}

-- Active frontend (default: C++)
local active_frontend_key = "cpp"

local function get_frontend()
	return frontends[active_frontend_key]
end

-- =============================================================================
-- Environment detection
-- =============================================================================

-- Get the GCC source root directory by walking up from current directory
-- Returns the directory containing the gcc/ subdirectory
local function get_gcc_root()
	local check_dir = vim.fn.getcwd()

	while check_dir ~= "/" do
		local gcc_dir = check_dir .. "/gcc"
		if vim.fn.isdirectory(gcc_dir) == 1 then
			return check_dir
		end
		check_dir = vim.fn.fnamemodify(check_dir, ":h")
	end

	return nil
end

-- Get the build root directory
-- First tries gcc_root/build, then parent_of_gcc_root/build
local function get_build_root(gcc_root)
	local build_in_source = gcc_root .. "/build"
	if vim.fn.isdirectory(build_in_source) == 1 then
		return build_in_source
	end

	local parent_dir = vim.fn.fnamemodify(gcc_root, ":h")
	local build_sibling = parent_dir .. "/build"
	if vim.fn.isdirectory(build_sibling) == 1 then
		return build_sibling
	end

	return nil
end

-- Detect the target architecture directory in the build tree
local function get_target_arch(build_root)
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

	for _, target in ipairs(common_targets) do
		local target_path = build_root .. "/" .. target
		local libstdcxx_path = target_path .. "/libstdc++-v3"
		if vim.fn.isdirectory(libstdcxx_path) == 1 then
			return target
		end
	end

	local find_cmd = string.format("find %s -maxdepth 2 -type d -name 'libstdc++-v3' 2>/dev/null", build_root)
	local handle = io.popen(find_cmd)
	local result = handle:read("*l")
	handle:close()

	if result then
		local target = result:match(build_root .. "/([^/]+)/libstdc%+%+%-v3")
		if target then
			return target
		end
	end

	return nil
end

-- Validate GCC environment and show helpful errors
-- Returns gcc_root, build_root, target_arch (target_arch may be nil for non-C++ frontends)
local function validate_gcc_env()
	local fe = get_frontend()

	local gcc_root = get_gcc_root()
	if not gcc_root then
		vim.notify(
			"Could not find GCC source directory.\n"
				.. "Please open Neovim from within your GCC source tree (anywhere inside the directory containing gcc/).",
			vim.log.levels.ERROR
		)
		return nil, nil, nil
	end

	local build_root = get_build_root(gcc_root)
	if not build_root then
		vim.notify(
			"Could not find build directory.\n"
				.. "Expected build/ either inside the GCC source directory or as a sibling to it.\n"
				.. "Looked for:\n"
				.. "  - "
				.. gcc_root
				.. "/build\n"
				.. "  - "
				.. vim.fn.fnamemodify(gcc_root, ":h")
				.. "/build",
			vim.log.levels.ERROR
		)
		return nil, nil, nil
	end

	-- Check for the frontend-specific driver binary
	local build_gcc = build_root .. "/gcc"
	local driver_path = build_gcc .. "/" .. fe.driver
	if vim.fn.executable(driver_path) ~= 1 then
		vim.notify(
			fe.name
				.. " driver not found.\n"
				.. "Expected "
				.. fe.driver
				.. " at: "
				.. driver_path
				.. "\n"
				.. 'Please run "make" in your build directory first.',
			vim.log.levels.ERROR
		)
		return nil, nil, nil
	end

	-- Check for the frontend binary
	local frontend_path = build_gcc .. "/" .. fe.frontend_binary
	if vim.fn.executable(frontend_path) ~= 1 then
		vim.notify(
			fe.name
				.. " frontend binary not found.\n"
				.. "Expected "
				.. fe.frontend_binary
				.. " at: "
				.. frontend_path
				.. "\n"
				.. 'Please run "make" in your build directory first.',
			vim.log.levels.ERROR
		)
		return nil, nil, nil
	end

	-- Detect target architecture (only required for frontends that need libstdc++)
	local target_arch = nil
	if fe.needs_libstdcxx then
		target_arch = get_target_arch(build_root)
		if not target_arch then
			vim.notify(
				"Could not detect target architecture.\n"
					.. "Expected to find libstdc++-v3 in build/<target-triplet>/ directory.\n"
					.. "Please ensure libstdc++ has been built.",
				vim.log.levels.ERROR
			)
			return nil, nil, nil
		end
	end

	return gcc_root, build_root, target_arch
end

-- =============================================================================
-- DejaGNU directive parsing
-- =============================================================================

local function parse_dejagnu_options(test_file)
	local file = io.open(test_file, "r")
	if not file then
		return ""
	end

	local options = {}
	local in_comment_block = false

	for line in file:lines() do
		-- Handle // style comments (works for both C++ and Rust)
		local comment = line:match("^%s*//(.*)$")
		if comment then
			local dg_options = comment:match('{ dg%-options "([^"]*)" }') or comment:match("{ dg%-options '([^']*)' }")
			if dg_options then
				table.insert(options, dg_options)
			end

			local dg_additional = comment:match('{ dg%-additional%-options "([^"]*)" }')
				or comment:match("{ dg%-additional%-options '([^']*)' }")
			if dg_additional then
				table.insert(options, dg_additional)
			end

			local dg_add = comment:match("{ dg%-add%-options (%S+)")
			if dg_add then
				local feature_flags = {
					pthread = "-pthread",
					tls = "-ftls-model=global-dynamic",
					bind_pic_locally = "-fPIE",
					c99_runtime = "-std=c99",
					ieee = "-fno-unsafe-math-optimizations",
				}
				if feature_flags[dg_add] then
					table.insert(options, feature_flags[dg_add])
				end
			end

			if comment:match("{ dg%-require%-effective%-target fopenmp }") then
				table.insert(options, "-fopenmp")
			end

			-- C++ standard version detection (only for C++ frontend)
			if active_frontend_key == "cpp" then
				local std_req = comment:match("{ dg%-require%-effective%-target c%+%+(%d+)")
					or comment:match("c%+%+(%d+)")
				if std_req and not line:match("dg%-options") then
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
		end

		-- Handle /* */ style comment blocks
		if line:match("/%*") then
			in_comment_block = true
		end
		if in_comment_block then
			local dg_options = line:match('{ dg%-options "([^"]*)" }')
			if dg_options then
				table.insert(options, dg_options)
			end
			local dg_additional = line:match('{ dg%-additional%-options "([^"]*)" }')
			if dg_additional then
				table.insert(options, dg_additional)
			end
			local dg_add = line:match("{ dg%-add%-options (%S+)")
			if dg_add then
				local feature_flags = {
					pthread = "-pthread",
					tls = "-ftls-model=global-dynamic",
					bind_pic_locally = "-fPIE",
					c99_runtime = "-std=c99",
					ieee = "-fno-unsafe-math-optimizations",
				}
				if feature_flags[dg_add] then
					table.insert(options, feature_flags[dg_add])
				end
			end
			if line:match("{ dg%-require%-effective%-target fopenmp }") then
				table.insert(options, "-fopenmp")
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

-- =============================================================================
-- Build command construction
-- =============================================================================

-- Build the driver command with proper include paths and flags
-- For C++: xg++ -B... -nostdinc++ -I(libstdc++ paths)... <extra_args> <test_file>
-- For Rust: gccrs -B... <extra_args> <test_file>
local function build_driver_command(gcc_root, build_root, target_arch, extra_args, test_file)
	local fe = get_frontend()
	local gcc_build = build_root .. "/gcc"
	local driver_path = gcc_build .. "/" .. fe.driver

	if fe.needs_libstdcxx and target_arch then
		local libstdcxx_build = build_root .. "/" .. target_arch .. "/libstdc++-v3"
		local libstdcxx_source = gcc_root .. "/libstdc++-v3"

		return string.format(
			"%s -B%s -nostdinc++ "
				.. "-I%s/include/%s "
				.. "-I%s/include "
				.. "-I%s/libsupc++ "
				.. "-I%s/include/backward "
				.. "-I%s/testsuite/util "
				.. "%s %s",
			driver_path,
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
	else
		return string.format("%s -B%s %s %s", driver_path, gcc_build, extra_args, test_file)
	end
end

-- Extract the frontend binary command from driver -v output
-- e.g. extracts the cc1plus or crab1 invocation line
local function get_frontend_command(test_file, extra_args)
	extra_args = extra_args or ""

	local dejagnu_opts = parse_dejagnu_options(test_file)
	if dejagnu_opts ~= "" then
		vim.notify("Parsed test options: " .. dejagnu_opts, vim.log.levels.INFO)
		extra_args = dejagnu_opts .. " " .. extra_args
	end

	local gcc_root, build_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return nil
	end

	local fe = get_frontend()
	local driver_cmd =
		build_driver_command(gcc_root, build_root, target_arch, extra_args .. " " .. fe.verbose_flag, test_file)
	local full_cmd = driver_cmd .. " 2>&1"

	local handle = io.popen(full_cmd)
	local output = handle:read("*a")
	handle:close()

	-- Extract the frontend binary invocation from -v output
	local pattern = "/" .. fe.frontend_binary .. "%s"
	local alt_pattern = "^%s*" .. fe.frontend_binary .. "%s"

	local frontend_line = nil
	for line in output:gmatch("[^\r\n]+") do
		if line:match(pattern) or line:match(alt_pattern) then
			frontend_line = line
			break
		end
	end

	if frontend_line then
		frontend_line = frontend_line:match("^%s*(.-)%s*$")
		frontend_line = frontend_line:gsub("%s+", " ")
		return frontend_line
	end

	return nil
end

-- =============================================================================
-- Commands
-- =============================================================================

-- Switch frontend
vim.api.nvim_create_user_command("GccSetFrontend", function(opts)
	local key = opts.args:lower()
	if key == "c++" or key == "cpp" or key == "g++" then
		key = "cpp"
	elseif key == "rust" or key == "gccrs" or key == "rs" then
		key = "rust"
	end

	if not frontends[key] then
		local available = {}
		for k, v in pairs(frontends) do
			table.insert(available, k .. " (" .. v.name .. ")")
		end
		vim.notify(
			"Unknown frontend: " .. opts.args .. "\nAvailable: " .. table.concat(available, ", "),
			vim.log.levels.ERROR
		)
		return
	end

	active_frontend_key = key
	vim.notify("Switched to frontend: " .. frontends[key].name, vim.log.levels.INFO)
end, {
	nargs = 1,
	complete = function()
		return { "cpp", "rust" }
	end,
})

-- Show current frontend
vim.api.nvim_create_user_command("GccFrontend", function()
	local fe = get_frontend()
	vim.notify(
		string.format(
			"Active frontend: %s (%s)\nDriver: %s | Binary: %s",
			active_frontend_key,
			fe.name,
			fe.driver,
			fe.frontend_binary
		),
		vim.log.levels.INFO
	)
end, { nargs = 0 })

-- Help command
vim.api.nvim_create_user_command("GccHelp", function()
	local help_text = [[
GCC Development Plugin for Neovim
==================================

This plugin streamlines GCC compiler development by providing commands to
debug, test, and navigate the GCC testsuite directly from Neovim.
Supports multiple frontends: C++ (g++) and Rust (gccrs).

QUICK START:
-----------
1. Open Neovim from anywhere in your GCC source tree
2. Run :GccCheck to verify your environment
3. Use :GccSetFrontend rust  to switch to gccrs (default: cpp)
4. Use :FindTest to search for tests
5. Press 'd' on a test to debug it with GDB

FRONTEND COMMANDS:
-----------------

:GccSetFrontend <frontend>
    Switch active frontend. Accepts: cpp, rust (also: g++, gccrs, rs, c++)
    Default: cpp

:GccFrontend
    Show the currently active frontend.

TEST COMMANDS:
--------------

:FindTest <pattern>
    Search for test files in the active frontend's testsuite.
    C++:  searches gcc/testsuite/g++.dg/ for .C/.cc files
    Rust: searches gcc/testsuite/rust/ for .rs files
    
    Keybindings in results window:
      <CR> - Open the test file for editing
      d    - Debug with GDB (runs :GdbFrontend)
      r    - Compile test (runs :RunTest)
      t    - Run via testsuite (runs :RunTestsuite)
      l    - Show test log
      q    - Close the results window

:GdbFrontend <test_file> [flags]
    Debug a test file with GDB. Extracts the frontend binary command
    (cc1plus for C++, crab1 for Rust) from the driver's verbose output.
    Uses -v for xg++ and --verbose for gccrs.
    Also available as :GdbCC1plus (alias).
    
    Examples:
      :GdbFrontend gcc/testsuite/g++.dg/cpp26/constexpr-virt1.C
      :GdbFrontend gcc/testsuite/rust/compile/test.rs

:RunTest <test_file>
    Quickly compile a test file using the active frontend's driver
    with proper paths. Parses DejaGNU directives automatically.

:RunTestsuite <test_file>
    Run the full DejaGNU testsuite for a specific test.
    C++:  make check-g++ RUNTESTFLAGS="dg.exp=<file>"
    Rust: auto-detects the test set from the path:
          rust/compile/foo.rs -> compile.exp=foo.rs
          rust/execute/bar.rs -> execute.exp=bar.rs

:ShowTestOptions <test_file>
    Display DejaGNU directives found in a test file.

:ShowTestLog
    Display the test log from the last testsuite run.

:GccCheck
    Verify your GCC environment for the active frontend.

SETUP REQUIREMENTS:
------------------
- GCC source tree with gcc/ directory
- build/ directory (either inside source or as a sibling)
- For C++:  xg++, cc1plus, and libstdc++-v3 built
- For Rust: gccrs and crab1 built

The plugin supports two directory structures:
  Structure 1: gcc-source/gcc/ and gcc-source/build/
  Structure 2: source/gcc/ and build/ (as siblings)

TROUBLESHOOTING:
---------------
- "driver not found": Run 'make' in your build directory
- "frontend binary not found": The frontend may not be built
- For gccrs: ensure you configured with --enable-languages=rust
- Use :GccCheck to diagnose environment issues

For more info: https://github.com/riogu/gcc1plus
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
	local fe = get_frontend()
	local gcc_root = get_gcc_root()

	if not gcc_root then
		vim.notify(
			"✗ GCC source not found.\n" .. "Please open Neovim from within your GCC source tree.",
			vim.log.levels.ERROR
		)
		return
	end

	local build_root = get_build_root(gcc_root)
	if not build_root then
		vim.notify(
			"✗ Build directory not found.\n" .. "Expected build/ either inside source or as a sibling.",
			vim.log.levels.ERROR
		)
		return
	end

	local target_arch = get_target_arch(build_root)

	local checks = {
		{ path = gcc_root .. "/gcc", desc = "GCC source directory" },
		{ path = build_root, desc = "Build directory" },
		{
			path = build_root .. "/gcc/" .. fe.driver,
			desc = fe.name .. " driver (" .. fe.driver .. ")",
			executable = true,
		},
		{
			path = build_root .. "/gcc/" .. fe.frontend_binary,
			desc = fe.name .. " frontend (" .. fe.frontend_binary .. ")",
			executable = true,
		},
	}

	-- Add libstdc++ checks only for frontends that need it
	if fe.needs_libstdcxx then
		table.insert(checks, {
			path = target_arch and (build_root .. "/" .. target_arch .. "/libstdc++-v3") or "",
			desc = "libstdc++ build",
		})
		table.insert(checks, { path = gcc_root .. "/libstdc++-v3", desc = "libstdc++ source" })
	end

	-- Add testsuite directory check
	table.insert(checks, {
		path = gcc_root .. "/gcc/testsuite/" .. fe.testsuite_subdir,
		desc = fe.name .. " testsuite directory",
	})

	local all_ok = true
	local results = {
		"GCC Environment Check [" .. fe.name .. "]",
		"===================",
		"",
		"Frontend:   " .. fe.name .. " (" .. active_frontend_key .. ")",
		"GCC Source: " .. gcc_root,
		"Build Root: " .. build_root,
	}

	if fe.needs_libstdcxx then
		table.insert(results, "Target:     " .. (target_arch or "NOT DETECTED"))
	end

	table.insert(results, "")

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
		table.insert(results, "✓ All checks passed! " .. fe.name .. " environment is ready.")
	else
		table.insert(results, '✗ Some checks failed. You may need to run "make" in your build directory.')
		if active_frontend_key == "rust" then
			table.insert(results, "  Hint: ensure you configured with --enable-languages=rust")
		end
	end

	vim.notify(table.concat(results, "\n"), all_ok and vim.log.levels.INFO or vim.log.levels.WARN)
end, { nargs = 0 })

-- Debug frontend binary with GDB
local function gdb_frontend_impl(opts)
	local args = vim.split(opts.args, "%s+")
	if #args < 1 then
		local fe = get_frontend()
		vim.notify("Usage: :GdbFrontend <test_file> [extra_flags]", vim.log.levels.ERROR)
		return
	end

	local test_file = args[1]
	local extra_args = #args > 1 and table.concat(vim.list_slice(args, 2), " ") or ""

	local gcc_root, build_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local fe = get_frontend()
	vim.notify("Extracting " .. fe.frontend_binary .. " command...", vim.log.levels.INFO)
	local frontend_cmd = get_frontend_command(test_file, extra_args)

	if frontend_cmd then
		local gcc_build = build_root .. "/gcc"
		vim.notify("Starting GDB session for: " .. vim.fn.fnamemodify(test_file, ":t"), vim.log.levels.INFO)

		local buftype = vim.api.nvim_buf_get_option(0, "buftype")
		if buftype == "nofile" or buftype == "terminal" then
			vim.cmd("enew")
		end

		vim.cmd(string.format("GdbStart gdb -cd=%s -x .gdbinit --args %s", gcc_build, frontend_cmd))
	else
		vim.notify(
			"Failed to extract "
				.. fe.frontend_binary
				.. " command.\n"
				.. "Check if "
				.. fe.driver
				.. " can compile the test.\n"
				.. "Try running: "
				.. fe.driver
				.. " -v "
				.. test_file,
			vim.log.levels.ERROR
		)
	end
end

vim.api.nvim_create_user_command("GdbFrontend", gdb_frontend_impl, { nargs = "+", complete = "file" })
-- Keep the old name as an alias for backward compatibility
vim.api.nvim_create_user_command("GdbCC1plus", gdb_frontend_impl, { nargs = "+", complete = "file" })

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

-- Build RUNTESTFLAGS string for a given test file
-- For C++: "dg.exp=<filename>"
-- For Rust: infers exp from directory, e.g. rust/compile/foo.rs -> "--all compile.exp=foo.rs"
local function get_runtestflags(test_file)
	local fe = get_frontend()
	local filename = test_file:match("([^/]+)$")

	if fe.runtestflags_fmt then
		return string.format(fe.runtestflags_fmt, filename)
	end

	-- For gccrs: infer test set from the parent directory
	-- e.g. .../rust/compile/foo.rs -> compile
	--      .../rust/execute/bar.rs -> execute
	local test_set = test_file:match("/rust/([^/]+)/[^/]+$")
	if test_set then
		return string.format("--all %s.exp=%s", test_set, filename)
	end

	-- Fallback: compile.exp
	vim.notify("Could not infer test set from path, defaulting to compile.exp", vim.log.levels.WARN)
	return string.format("--all compile.exp=%s", filename)
end

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

	local gcc_root, build_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local fe = get_frontend()
	local build_gcc = build_root .. "/gcc"
	local runtestflags = get_runtestflags(test_file)
	local cmd = string.format('cd %s && make %s RUNTESTFLAGS="%s"', build_gcc, fe.check_target, runtestflags)

	vim.notify("Running testsuite: " .. fe.check_target .. " " .. runtestflags, vim.log.levels.INFO)
	vim.cmd("terminal " .. cmd)
end, { nargs = 1, complete = "file" })

-- Show test log
vim.api.nvim_create_user_command("ShowTestLog", function()
	local gcc_root, build_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local fe = get_frontend()
	local log_file = nil
	for _, pattern in ipairs(fe.log_patterns) do
		local full_path = build_root .. "/" .. pattern
		if vim.fn.filereadable(full_path) == 1 then
			log_file = full_path
			break
		end
	end

	if not log_file then
		vim.notify(fe.name .. " test log not found. Run :RunTestsuite first to generate logs.", vim.log.levels.WARN)
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
	vim.notify("Showing " .. fe.name .. " test log (press q to close)", vim.log.levels.INFO)
end, { nargs = 0 })

-- Run test quickly
vim.api.nvim_create_user_command("RunTest", function(opts)
	if opts.args == "" then
		vim.notify("Usage: :RunTest <test_file>", vim.log.levels.ERROR)
		return
	end

	local test_file = opts.args
	local gcc_root, build_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local fe = get_frontend()
	local dejagnu_opts = parse_dejagnu_options(test_file)
	local gcc_build = build_root .. "/gcc"
	local abs_test_file = vim.fn.fnamemodify(test_file, ":p")

	local cmd = string.format(
		"cd %s && %s",
		gcc_build,
		build_driver_command(gcc_root, build_root, target_arch, dejagnu_opts, abs_test_file)
	)

	local test_name = vim.fn.fnamemodify(test_file, ":t")
	vim.notify(
		string.format(
			"[%s] Compiling: %s%s",
			fe.name,
			test_name,
			dejagnu_opts ~= "" and " (with options: " .. dejagnu_opts .. ")" or ""
		),
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
	local gcc_root, build_root, target_arch = validate_gcc_env()
	if not gcc_root then
		return
	end

	local fe = get_frontend()
	local testsuite_path = gcc_root .. "/gcc/testsuite/" .. fe.testsuite_subdir

	-- Build find command for all supported extensions
	local ext_patterns = {}
	for _, ext in ipairs(fe.test_extensions) do
		table.insert(ext_patterns, string.format("-path '*%s*.%s'", pattern, ext))
	end
	local find_cmd = string.format("find %s %s", testsuite_path, table.concat(ext_patterns, " -o "))

	vim.notify(string.format("[%s] Searching for tests matching: %s", fe.name, pattern), vim.log.levels.INFO)

	local handle = io.popen(find_cmd)
	local results = handle:read("*a")
	handle:close()

	local lines = {}
	for line in results:gmatch("[^\r\n]+") do
		table.insert(lines, line)
	end

	if #lines == 0 then
		vim.notify("No tests found matching: " .. pattern .. " in " .. fe.testsuite_subdir, vim.log.levels.WARN)
		return
	end

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

	local keymaps = {
		{ key = "<CR>", cmd = "edit", desc = "Open test file" },
		{ key = "d", cmd = "GdbFrontend", desc = "Debug with GDB" },
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
		string.format(
			"[%s] Found %d tests. Use: <CR>=open | d=debug | r=compile | t=testsuite | l=log | q=quit",
			fe.name,
			#lines
		),
		vim.log.levels.INFO
	)
end, { nargs = 1 })
