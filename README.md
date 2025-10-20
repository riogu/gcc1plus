# gcc1plus

Neovim plugin for GCC compiler development. Provides integrated debugging and testing workflows for the GCC testsuite.

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

### Commands

| Command | Function |
|---------|----------|
| `:GdbCC1plus <file> [flags]` | Launch GDB with extracted cc1plus command |
| `:RunTest <file>` | Compile test file with xg++ |
| `:RunTestsuite <file>` | Execute test via `make check-g++` |
| `:FindTest <pattern>` | Search testsuite for matching files |
| `:ShowTestOptions <file>` | Display parsed DejaGNU directives |
| `:ShowTestLog` | Open `g++.log` from last testsuite run |
| `:GccCheck` | Verify build environment |
| `:GccHelp` | Display detailed usage information |

### Examples

```vim
:GdbCC1plus gcc/testsuite/g++.dg/cpp26/constexpr-virt1.C -O2
:RunTest gcc/testsuite/g++.dg/template/crash115.C
:RunTestsuite gcc/testsuite/g++.dg/cpp2a/concepts-pr67178.C
:FindTest constexpr
```

### Interactive Test Search

`:FindTest <pattern>` opens a buffer with matching test files. Available keybindings:

| Key | Action |
|-----|--------|
| `<CR>` | Open test file |
| `d` | Debug with GDB (`:GdbCC1plus`) |
| `r` | Compile test (`:RunTest`) |
| `t` | Run via testsuite (`:RunTestsuite`) |
| `l` | Show test log |
| `q` | Close window |

## Implementation Details

### Root Detection

The plugin walks up the directory tree from `getcwd()` searching for a directory containing both `gcc/` and `build/` subdirectories.

### DejaGNU Directive Parsing

Parses the following directives from test files:
- `{ dg-options "..." }`
- `{ dg-additional-options "..." }`
- `{ dg-require-effective-target c++NN }`

Directives are extracted from C++ (`//`) and C (`/* */`) style comments within the first 2000 bytes of the test file.

### cc1plus Command Extraction

Runs `xg++ -v` with proper include paths and parses the cc1plus invocation from verbose output. Include paths are automatically configured for:
- `build/x86_64-pc-linux-gnu/libstdc++-v3/include/`
- `libstdc++-v3/libsupc++/`
- `libstdc++-v3/include/backward/`
- `libstdc++-v3/testsuite/util/`

### Environment Validation

`:GccCheck` verifies:
- GCC root directory structure
- Build directory exists
- xg++ binary is executable
- cc1plus binary exists
- libstdc++-v3 source and build directories

## Typical Development Workflow

1. Modify GCC source code
2. Rebuild: `cd build && make`
3. Locate relevant tests: `:FindTest <pattern>`
4. Debug regression: Press `d` on test file
5. Verify fix: Press `t` to run via testsuite
6. Check results: Press `l` to view `g++.log`

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
    └── x86_64-pc-linux-gnu/
        └── libstdc++-v3/
```

## Limitations

- Assumes x86_64-pc-linux-gnu target architecture
- DejaGNU directive parsing may not handle all edge cases
- Requires standard GCC build directory layout

## Contributing

Bug reports and patches welcome. Submit via GitHub issues or pull requests.

## License

MIT License

## References

- [GCC Testing Documentation](https://gcc.gnu.org/install/test.html)
- [DejaGNU Documentation](https://www.gnu.org/software/dejagnu/manual/)
- [nvim-gdb](https://github.com/sakhnik/nvim-gdb)
