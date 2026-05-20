# Minishell — Test Runner

Automated test suite for minishell projects. Compares your shell against bash on every test case, checks for memory leaks with valgrind, and catches crashes / segfaults.

---

## Requirements

- `valgrind` (`apt install valgrind`)
- `python3` in PATH
- A compiled `minishell` binary (the script compiles it automatically with `make re`)

---

## Quick start

```bash
# Copy run_all.sh into your project root, then:
./run_all.sh
```

---

## Usage

```
./run_all.sh [N | N-M] [-e [N | N-M]] [-c] [-l] [-w]
```

### Section filter (positional)

| Syntax | Effect |
|--------|--------|
| *(none)* | Run all 22 sections |
| `N` | Run only section N |
| `N-M` | Run sections N through M (inclusive) |

### Output filter (flags)

Without any flag, **every result type** is shown. Adding a flag restricts output to only the selected types.

| Flag | Shows |
|------|-------|
| `-e` | **FAIL** — stdout or exit code differs from bash |
| `-w` | **WARN** — minishell printed unexpected stderr |
| `-l` | **LEAK** — valgrind detected a memory leak or invalid access |
| `-c` | **CRASH** — segfault, killed by signal, or timeout |

Flags are **fully combinable** in any order:

```bash
./run_all.sh -e              # only FAILs, all sections
./run_all.sh -l              # only LEAKs, all sections
./run_all.sh -cl             # CRASHes + LEAKs
./run_all.sh -eclw           # all four types at once
./run_all.sh 8 -l            # only LEAKs in section 8
./run_all.sh -e 5-7          # only FAILs in sections 5 to 7
./run_all.sh 5-7 -cl         # CRASHes + LEAKs in sections 5 to 7
./run_all.sh -e 8 -l         # FAILs + LEAKs in section 8
```

### Binary override

```bash
MINI_BIN=./my_binary ./run_all.sh
```

By default the script looks for `./minishell`. Use `MINI_BIN` to point to a different binary (compilation still runs, but the specified binary is used for tests).

---

## Result statuses

| Status | Meaning |
|--------|---------|
| `[OK  ]` | stdout, exit code, and stderr all match bash |
| `[WARN]` | Output matches but minishell produced unexpected stderr |
| `[FAIL]` | stdout or exit code differs from bash |
| `[CLEAN]` | `vcheck` only — no crash and valgrind is clean |
| `[LEAK  ]` | `vcheck` only — valgrind found leaks or memory errors |
| `[CRASH  ]` | Process killed by signal (exit 134–139) |
| `[TIMEOUT]` | Process did not exit within 5 seconds |

Leak detection appends a suffix to any status:

```
[OK  ] simple pipe          → correct output, no leak
[OK  ]+LEAK simple pipe     → correct output but leaks
[FAIL]+LEAK simple pipe     → wrong output and leaks
```

### Colors

```
[FAIL]  [CRASH]  [LEAK]   → red
[WARN]                    → yellow
[OK  ]  [CLEAN]           → green
$> <command>              → cyan
```

The progress counter `[XX%] N/TOTAL` is updated in place on the same line.

---

## Log file

Every run **overwrites** `logs_full_test.txt` with a plain-text (no ANSI) copy of all results. Full valgrind output is included for every leaking test.

```bash
# Useful greps after a run:
grep FAIL logs_full_test.txt
grep LEAK logs_full_test.txt
grep CRASH logs_full_test.txt
```

---

## Test sections

| # | Category | What is tested |
|---|----------|----------------|
| 1 | PIPES | Basic pipes, long chains, invalid commands, exit codes |
| 2 | REDIRECTIONS | `>` `>>` `<` `<<`, no filename, permissions, `/dev/full`, directory targets |
| 3 | HEREDOC | Basic, empty body, unterminated, variable expansion, quoted delimiter |
| 4 | QUOTES | Single / double / mixed / unclosed / nested quotes |
| 5 | VARIABLES / EXPANSION | `$VAR`, `$?`, `$HOME`, undefined vars, `$` alone or before digit |
| 6 | BUILTINS — echo | `-n` flag, multiple args, empty string, empty quotes |
| 7 | BUILTINS — cd | No arg, `/`, `..`, `.`, nonexistent path, missing HOME, too many args |
| 8 | BUILTINS — export | Valid / invalid names, quote wrapping, `VAR` vs `VAR=`, alphabetical order |
| 9 | BUILTINS — unset | No args, invalid names, unset HOME / PATH |
| 10 | BUILTINS — exit | Non-numeric, overflow, leading zeros, `+`/`-` signs, quotes, too many args |
| 11 | BUILTINS — env / pwd | Basic output, extra arguments |
| 12 | COMMANDES INTROUVABLES | Exit 127 not found, exit 126 no permission, relative and absolute paths |
| 13 | SANS PATH / ENV VIDE | Commands run with stripped PATH or completely empty environment |
| 14 | EDGE CASES | Empty input, only spaces, very long args, 300 args, `$?` in pipes |
| 15 | TESTS REPOS ETUDIANTS | Crash baits from student repos: operator hell, quote madness, exit overflow, export abuse, heredoc extremes, syntax errors |
| 16 | FILESYSTEM | `cd` into a directory deleted underneath; file created then removed mid-session |
| 17 | SIGNAUX | `SIGINT (^C)` during blocking commands, heredoc, long pipes; `$?` after pipelines with invalid commands |
| 18 | TESTS DES MALADES | 100-pipe chains, `yes | head`, parsing edge cases, 500-line heredoc, mass export/unset, `exit` in pipelines, file descriptor leaks |
| 19 | HEREDOC EXTREMES | Unusual delimiters, quoted delimiters, 1000-line bodies, multiple sequential heredocs, heredoc + SIGINT |
| 20 | PATH POISONNING | Fake binaries in PATH that shadow builtins; builtins must not be overridden; SIGINT on blocking fake binary |
| 21 | ENV -I | All tests run with `env -i` (fully empty environment); PWD/OLDPWD management, `cd -`, `export`, pipes, heredoc |
| 22 | COMPLEMENTS | Single-char commands, echo `-n` variants, variable terminators, exit with quotes, pipe + echo stdin, redirection before command name |

---

## Internal test functions

| Function | Description |
|----------|-------------|
| `check` | Runs input in minishell and bash, compares stdout / stderr / exit code. Also runs valgrind on the same input. |
| `check_ei` | Same as `check` but both shells are launched with `env -i` (no environment). No valgrind (env -i + valgrind is unstable). |
| `vcheck` | Runs only through minishell — no bash comparison. Detects crashes first, then valgrind for leaks. Accepts an optional `env_prefix` third argument. |
| `sigtest` | Keeps minishell's stdin open via a background `sleep`, sends `SIGINT` after a configurable delay, and checks that the process did not crash. |

---

## Valgrind suppressions

`readline.supp` is created automatically on first run if it does not exist. It suppresses known internal leaks from readline / ncurses so only **your** leaks appear in results.

Suppressed symbols:
```
fun:readline
fun:rl_*
fun:add_history
fun:history_*
obj:libreadline.so*
obj:libncurses.so*
obj:libtinfo.so*
```

Valgrind options used:

```
--leak-check=full
--show-leak-kinds=all
--track-fds=yes
--track-origins=yes
--trace-children=yes
--error-exitcode=99
-q
```

Exit code `99` from valgrind is treated as a leak/error regardless of the actual memory report lines.

---

## Cleanup

After each run the script removes:
- All `/tmp/ra_*` files created during tests
- Any files created in the current working directory during the run (detected via a before/after directory snapshot)

---

## Tips

```bash
# Focus on your worst bugs first
./run_all.sh -e          # all failures
./run_all.sh -ec         # failures + crashes

# Debug a specific category
./run_all.sh 8           # export tests only
./run_all.sh 8 -e        # only failing export tests

# Check memory only
./run_all.sh -l          # all leaks
./run_all.sh 1-5 -l      # leaks in pipes, redirections, heredoc, quotes, variables

# Full log review after a run
grep -A5 "FAIL" logs_full_test.txt
grep -A20 "LEAK" logs_full_test.txt
```
