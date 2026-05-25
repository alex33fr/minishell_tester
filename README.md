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
./run_all.sh          # full run with valgrind
./run_all.sh --l      # full run without valgrind (much faster)
```

---

## Usage

```
./run_all.sh [N | N-M] [-e [N | N-M]] [-c] [-l] [-w] [--l]
```

### Section filter (positional)

| Syntax | Effect |
|--------|--------|
| *(none)* | Run all 34 sections |
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
| `--l` | **No valgrind** — show all result types but skip valgrind entirely (much faster) |

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
./run_all.sh 22-34           # run only the extended sections
./run_all.sh --l             # full run, no valgrind (quick check)
./run_all.sh 8 --l           # section 8, no valgrind
```

### Binary override

```bash
MINI_BIN=./my_binary ./run_all.sh
```

By default the script looks for `../minishell`. Use `MINI_BIN` to point to a different binary (compilation still runs, but the specified binary is used for tests).

---

## Prompt detection

The tester uses `fake_readline.so` (compiled automatically) to intercept `readline()` and force a fixed prompt `MINIT: `, so the prompt never pollutes the test output.

If the minishell does not use `readline()` (static build, custom input function, etc.), the script detects this automatically and falls back to dynamic prompt detection: it runs the minishell on empty input, captures whatever prompt it prints, and uses that to strip prompts from all test outputs. ANSI color codes in the prompt are handled correctly.

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
[OK  +LEAK] simple pipe     → correct output but leaks
[FAIL+LEAK] simple pipe     → wrong output and leaks
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

Every run **overwrites** `logs_full_test.txt` with a plain-text (no ANSI codes) record of **every test**, not just failures. The file starts with a header showing the date, binary path, and mode.

Format per test:
```
[FAIL] Test 5: pipe no left
  cmd  : | ls
  mini : exit=0  out=
  bash : exit=2  out=
  diff : exit code (mini=0 bash=2)
  diff : stderr

[OK] Test 13: pipe 20x ls
  cmd  : ls | ls | ls | ...
  mini : exit=0  out=check_allowed.sh
```

```bash
# Useful greps after a run:
grep "^\[FAIL\]" logs_full_test.txt
grep "^\[CRASH\]" logs_full_test.txt
grep "^\[LEAK\]" logs_full_test.txt
grep "diff :" logs_full_test.txt
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
| 12 | COMMANDES INTROUVABLES / PERMISSIONS | Exit 127 not found, exit 126 no permission, relative and absolute paths |
| 13 | SANS PATH / ENV VIDE | Commands run with stripped PATH or completely empty environment |
| 14 | EDGE CASES | Empty input, only spaces, very long args, 300 args, `$?` in pipes |
| 15 | TESTS REPOS ETUDIANTS | Crash baits from student repos: operator hell, quote madness, exit overflow, export abuse, heredoc extremes, syntax errors |
| 16 | FILESYSTEM | `cd` into a directory deleted underneath; file created then removed mid-session |
| 17 | SIGNAUX | `SIGINT (^C)` during blocking commands, heredoc, long pipes; `$?` after pipelines with invalid commands |
| 18 | TESTS DES MALADES | `$$` / `;` / `&`, echo `-e`/`-E`, 100-pipe chains, `yes \| head`, parsing edge cases, 500-line heredoc, mass export/unset, `exit` in pipelines, file descriptor leaks |
| 19 | HEREDOC — TESTS EXTRÊMES | Empty/whitespace-only delimiter, quoted delimiters, 1000-line bodies, multiple sequential heredocs, heredoc + SIGINT |
| 20 | PATH POISONNING | Fake binaries in PATH that shadow builtins; builtins must not be overridden; SIGINT on blocking fake binary |
| 21 | ENV -I | All tests run with `env -i` (fully empty environment); PWD/OLDPWD management, `cd -`, `export`, pipes, heredoc |
| 22 | COMPLÉMENTS DOCUMENT 800 | `$9VAR` positional param + literal, `$$` PID width, echo `-n` variants, redirection before command name |
| 23 | SYNTAX ERRORS | Invalid pipe/redirect sequences: `\| \|`, `\| \| \|`, trailing `\|`, trailing `>`, `>>` with no file |
| 24 | ECHO — CAS AVANCÉS | Adjacent quotes in argument (`hello'world'`), empty double-quotes (`hello""world`), multiple `-n` flags |
| 25 | VARIABLES — CAS AVANCÉS | Empty var followed by text, `$?` immediately after command, `$$` PID via pipe and `wc -c` |
| 26 | QUOTES — COMBINAISONS AVANCÉES | Command split across quotes (`prin"tf"`), `$VAR` in double quotes, nested expansions |
| 27 | EXPORT / UNSET — EDGE CASES | Export then env grep, export+unset leaves no trace, `export VAR` without value |
| 28 | EXIT — EDGE CASES | `exit 123`, `exit 256` wraps to 0, non-numeric arg, too many args exit code |
| 29 | HEREDOC — EDGE CASES | Redirection before command (`<< end cat -e`), multi-line body |
| 30 | PWD — EDGE CASES | `pwd` alone, `pwd \| cat -e`, `cd /tmp; pwd; cd -; pwd` round-trip |
| 31 | REDIRECTIONS — AVANCÉES | Stdin from file piped to filter (`< /etc/hostname cat \| md5sum`), non-existent file + pipe |
| 32 | COMMANDES DIVERSES | `$PWD` as command, empty-var as command, `true`/`false` exit codes |
| 33 | ENV — FILTRAGE ET UNSET | `env \| grep USER/HOME`, unset then env grep, export visible in env |
| 34 | EXTRA PIPE CHAINS | 6-stage pipe (`ls\|ls\|…\|cat -e`), pipes with no spaces, pipe + exit code propagation |

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
# Quick full check without valgrind (much faster)
./run_all.sh --l

# Focus on your worst bugs first
./run_all.sh -e          # all failures
./run_all.sh -ec         # failures + crashes

# Debug a specific category
./run_all.sh 8           # export tests only
./run_all.sh 8 -e        # only failing export tests
./run_all.sh 8 --l       # section 8, no valgrind

# Check memory only
./run_all.sh -l          # all leaks
./run_all.sh 1-5 -l      # leaks in pipes, redirections, heredoc, quotes, variables
./run_all.sh 18-21 -e    # failures in edge-case / env-i sections

# Read the log
grep "^\[FAIL\]" logs_full_test.txt
grep "diff :" logs_full_test.txt
grep -A5 "^\[FAIL\]" logs_full_test.txt
```
