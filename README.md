# gcc1plus
Neovim plugin for GCC compiler development. Provides integrated debugging and testing workflows for the GCC testsuite.
The plugin is also showcased in this [video demonstration](https://www.youtube.com/watch?v=m0yDte273IQ)

## Overview
This plugin automates common GCC development tasks:
- Extracting cc1plus invocations from xg++ for GDB debugging
- Parsing DejaGNU test directives (dg-options, dg-additional-options, dg-require-effective-target)
- Running testsuite cases with proper libstdc++ include paths
- Navigating and executing tests from within the editor

## Requirements
- Neovim ≥ 0.8.0
- GCC source tree with configured build directory
- Compiled xg++ and cc1plus binaries in `build/gcc/`
- [nvim-gdb](https://github.com/sakhnik/nvim-gdb) (optional, required for `:GdbCC1plus`)

## Installation
### lazy.nvim
```lua
{
  'riogu/gcc1plus',
  dependencies = {
    { 'sakhnik/nvim-gdb', build = './install.sh' },
  },
}
```
### packer.nvim
```lua
use {
  'riogu/gcc1plus',
  requires = { 'sakhnik/nvim-gdb', run = './install.sh' },
}
```
### vim-plug
```vim
Plug 'sakhnik/nvim-gdb', { 'do': './install.sh' }
Plug 'riogu/gcc1plus'
```

## Usage
Open Neovim from any directory within your GCC source tree. The plugin automatically locates the root by searching for `gcc/` and `build/` directories.

### Interactive Test Search with FindTest
**`:FindTest`** is the primary interface for working with GCC tests. It searches the testsuite and opens an interactive buffer where you can quickly navigate, compile, debug, or run tests.

#### Quick Start
```vim
:FindTest constexpr
```
This opens a split window with all matching test files. Use these keybindings:

| Key | Action |
|-----|--------|
| `<CR>` | Open test file |
| `d` | Debug with GDB (`:GdbCC1plus`) |
| `r` | Compile test (`:RunTest`) |
| `t` | Run via testsuite (`:RunTestsuite`) |
| `l` | Show test log |
| `q` | Close window |

#### Example Workflows

**Search by filename:**
```vim
:FindTest constexpr-virt1
" Navigate to the test you want, press 'd' to start debugging in GDB
```

**Search by directory path:**
```vim
:FindTest cpp26/constexpr       " All constexpr tests in cpp26
:FindTest template/             " All tests in template directory
:FindTest cpp2a/concepts        " C++20 concepts tests
```

**Search by feature or bug number:**
```vim
:FindTest concepts              " All concepts-related tests
:FindTest pr12345               " Tests for bug report #12345
:FindTest crash                 " Tests that previously caused crashes
```

#### Usage Example
1. Make changes to GCC frontend code (e.g., in `gcc/cp/`)
2. Run `:FindTest <relevant-feature>` to find related tests
3. Press `r` to compile tests and verify your changes
4. Press `d` to debug any failing tests with GDB
5. Press `t` to run official testsuite validation
6. Press `l` to view test logs and PASS/FAIL results

### Commands
| Command | Function |
|---------|----------|
| `:FindTest <pattern>` | Search testsuite for matching files |
| `:GdbCC1plus <file> [flags]` | Launch GDB with extracted cc1plus command |
| `:RunTest <file>` | Compile test file with xg++ |
| `:RunTestsuite <file>` | Execute test via `make check-g++` |
| `:ShowTestOptions <file>` | Display parsed DejaGNU directives |
| `:ShowTestLog` | Open `g++.log` from last testsuite run |
| `:GccCheck` | Verify build environment |
| `:GccHelp` | Display detailed usage information |

### Direct Command Examples
```vim
:GdbCC1plus gcc/testsuite/g++.dg/cpp26/constexpr-virt1.C -O2
:RunTest gcc/testsuite/g++.dg/template/crash115.C
:RunTestsuite gcc/testsuite/g++.dg/cpp2a/concepts-pr67178.C
```

## Implementation Details
### Root Detection
The plugin walks up the directory tree from `getcwd()` searching for a directory containing both `gcc/` and `build/` subdirectories.

### Architecture Detection
Automatically detects the target architecture by searching for `libstdc++-v3` in the build directory. Supports common targets including:
- x86_64-pc-linux-gnu / x86_64-linux-gnu
- aarch64-linux-gnu
- arm-linux-gnueabihf
- powerpc64le-linux-gnu
- riscv64-linux-gnu
- s390x-linux-gnu
- i686-pc-linux-gnu / i686-linux-gnu

### DejaGNU Directive Parsing
Parses the following directives from test files:
- `{ dg-options "..." }`
- `{ dg-additional-options "..." }`
- `{ dg-require-effective-target c++NN }`

Directives are extracted from C++ (`//`) and C (`/* */`) style comments within the first 2000 bytes of the test file.

### cc1plus Command Extraction
Runs `xg++ -v` with proper include paths and parses the cc1plus invocation from verbose output. Include paths are automatically configured for:
- `build/<target-triplet>/libstdc++-v3/include/`
- `libstdc++-v3/libsupc++/`
- `libstdc++-v3/include/backward/`
- `libstdc++-v3/testsuite/util/`

### Environment Validation
`:GccCheck` verifies:
- GCC root directory structure
- Build directory exists
- xg++ binary is executable
- cc1plus binary exists
- Target architecture detected
- libstdc++-v3 source and build directories

## Directory Structure
The plugin expects the following GCC tree structure:
```
gcc-root/
├── gcc/
│   ├── cp/
│   ├── testsuite/
│   │   └── g++.dg/
│   └── ...
├── libstdc++-v3/
│   ├── include/
│   ├── libsupc++/
│   └── testsuite/
└── build/
    ├── gcc/
    │   ├── xg++
    │   ├── cc1plus
    │   └── testsuite/
    └── <target-triplet>/
        └── libstdc++-v3/
```

## References
- [DejaGNU Documentation](https://www.gnu.org/software/dejagnu/manual/)
- [nvim-gdb](https://github.com/sakhnik/nvim-gdb)
