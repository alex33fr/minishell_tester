#!/bin/bash

cd "$(dirname "$0")"
MINI="${1:-${MINI_BIN:-./minishell}}"
if [[ "$MINI" == -* ]]; then MINI="${MINI_BIN:-./minishell}"; fi
if [ ! -x "$MINI" ]; then
	echo "ERROR — binaire introuvable : $MINI" >&2; exit 1
fi

if [ ! -f ./readline.supp ]; then
	cat > ./readline.supp <<'SUPP'
{
   readline_leaks
   Memcheck:Leak
   ...
   fun:readline
}
{
   readline_leaks_2
   Memcheck:Leak
   ...
   fun:rl_*
}
{
   add_history_leaks
   Memcheck:Leak
   ...
   fun:add_history
}
{
   history_leaks
   Memcheck:Leak
   ...
   fun:history_*
}
{
   readline_internal
   Memcheck:Leak
   ...
   obj:*/libreadline.so*
}
{
   ncurses_leaks
   Memcheck:Leak
   ...
   obj:*/libncurses.so*
}
{
   ncurses_tinfo_leaks
   Memcheck:Leak
   ...
   obj:*/libtinfo.so*
}
SUPP
fi

VG="valgrind --leak-check=full --show-leak-kinds=all --track-fds=yes --track-origins=yes --suppressions=./readline.supp --error-exitcode=42"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

LEAKS=0
CLEAN=0
PASS=0
DIFF=0

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  TESTS SANS PATH (unset PATH / env vide)${NC}"
echo -e "${CYAN}================================================================${NC}"

run_cmp() {
	local desc="$1"
	local input="$2"
	local env_prefix="$3"

	mini_out=$(printf '%s' "$input" | timeout 5 env -i $env_prefix "$MINI" 2>&1)
	mini_exit=$?
	bash_out=$(printf '%s' "$input" | timeout 5 env -i $env_prefix bash --norc --noprofile 2>&1)
	bash_exit=$?

	if [ "$mini_out" = "$bash_out" ] && [ "$mini_exit" = "$bash_exit" ]; then
		echo -e "${GREEN}[OK   ] ${desc}${NC}"
		((PASS++))
	else
		echo -e "${YELLOW}[DIFF ] ${desc}${NC}"
		echo -e "  input : $input"
		echo -e "  mini  : $mini_out [exit=$mini_exit]"
		echo -e "  bash  : $bash_out [exit=$bash_exit]"
		((DIFF++))
	fi
}

vg_nopath() {
	local desc="$1"
	local input="$2"
	local env_prefix="$3"

	out=$(printf '%s' "$input" | timeout 10 env -i $env_prefix $VG "$MINI" 2>&1)
	code=$?

	lost=$(echo "$out" | grep -E "definitely lost|indirectly lost|still reachable" | grep -v "0 bytes")
	errors=$(echo "$out" | grep "ERROR SUMMARY" | grep -v "0 errors")

	if [ $code -eq 42 ] || [ -n "$lost" ] || [ -n "$errors" ]; then
		echo -e "${RED}[LEAK ] ${desc}${NC}"
		echo -e "  input : $input"
		echo "$out" | grep -E "definitely lost|indirectly lost|still reachable|ERROR SUMMARY|Invalid" | grep -v "0 bytes" | grep -v "0 errors" | sed 's/^/  /'
		((LEAKS++))
	else
		echo -e "${GREEN}[CLEAN] ${desc}${NC}"
		((CLEAN++))
	fi
}

# ─────────────────────────────────────────────
echo -e "\n${CYAN}[A] SANS PATH — commandes avec chemin absolu${NC}"
# ─────────────────────────────────────────────
run_cmp "ls absolu sans PATH"        "/bin/ls /tmp"                   "HOME=/tmp"
run_cmp "echo absolu sans PATH"      "/bin/echo hello"                "HOME=/tmp"
run_cmp "cat absolu sans PATH"       "/bin/cat /dev/null"             "HOME=/tmp"
run_cmp "pwd sans PATH"              "pwd"                            "HOME=/tmp"
run_cmp "echo builtin sans PATH"     "echo hello"                     "HOME=/tmp"
run_cmp "cd sans PATH"               "cd /tmp"                        "HOME=/tmp"
run_cmp "export sans PATH"           "export TOTO=1"                  "HOME=/tmp"
run_cmp "env sans PATH"              "env"                            "HOME=/tmp"
run_cmp "exit sans PATH"             "exit 0"                         "HOME=/tmp"

# ─────────────────────────────────────────────
echo -e "\n${CYAN}[B] SANS PATH — commandes sans chemin (doivent échouer)${NC}"
# ─────────────────────────────────────────────
run_cmp "ls sans PATH"               "ls"                             "HOME=/tmp"
run_cmp "cat sans PATH"              "cat /dev/null"                  "HOME=/tmp"
run_cmp "grep sans PATH"             "grep hello /dev/null"           "HOME=/tmp"
run_cmp "pipe sans PATH"             "ls | cat"                       "HOME=/tmp"
run_cmp "pipe absolu sans PATH"      "/bin/ls | /bin/cat"             "HOME=/tmp"
run_cmp "cmd not found sans PATH"    "thiscmddoesnotexist"            "HOME=/tmp"

# ─────────────────────────────────────────────
echo -e "\n${CYAN}[C] ENV COMPLETEMENT VIDE${NC}"
# ─────────────────────────────────────────────
run_cmp "echo env vide"              "echo hello"                     ""
run_cmp "pwd env vide"               "pwd"                            ""
run_cmp "exit env vide"              "exit 0"                         ""
run_cmp "export env vide"            "export A=1"                     ""
run_cmp "env env vide"               "env"                            ""
run_cmp "expand HOME env vide"       "echo \$HOME"                    ""
run_cmp "expand PATH env vide"       "echo \$PATH"                    ""
run_cmp "expand ? env vide"          "echo \$?"                       ""
run_cmp "cmd sans PATH env vide"     "ls"                             ""
run_cmp "absolu env vide"            "/bin/echo hello"                ""
run_cmp "pipe absolu env vide"       "/bin/echo hi | /bin/cat"        ""
run_cmp "redir env vide"             "/bin/echo hi > /tmp/vg_ev.txt"  ""
run_cmp "heredoc env vide"           $'/bin/cat <<EOF\nhello\nEOF'    ""
run_cmp "cd env vide sans HOME"      "cd"                             ""
run_cmp "unset env vide"             "unset A"                        ""

# ─────────────────────────────────────────────
echo -e "\n${CYAN}[D] PATH='' (vide)${NC}"
# ─────────────────────────────────────────────
run_cmp "ls PATH vide"               "ls"                             "PATH= HOME=/tmp"
run_cmp "echo builtin PATH vide"     "echo hello"                     "PATH= HOME=/tmp"
run_cmp "absolu PATH vide"           "/bin/ls /tmp"                   "PATH= HOME=/tmp"
run_cmp "pipe PATH vide"             "ls | cat"                       "PATH= HOME=/tmp"
run_cmp "cmd not found PATH vide"    "thiscmddoesnotexist"            "PATH= HOME=/tmp"

# ─────────────────────────────────────────────
echo -e "\n${CYAN}[E] VALGRIND — fuites sans PATH${NC}"
# ─────────────────────────────────────────────
vg_nopath "echo sans PATH"           "echo hello"                     "HOME=/tmp"
vg_nopath "cmd not found sans PATH"  "ls"                             "HOME=/tmp"
vg_nopath "pipe absolu sans PATH"    "/bin/echo hi | /bin/cat"        "HOME=/tmp"
vg_nopath "pipe cmd not found"       "ls | cat"                       "HOME=/tmp"
vg_nopath "export sans PATH"         "export A=hello"                 "HOME=/tmp"
vg_nopath "env vide echo"            "echo hello"                     ""
vg_nopath "env vide cmd not found"   "ls"                             ""
vg_nopath "env vide pipe"            "ls | cat"                       ""
vg_nopath "env vide pipe absolu"     "/bin/echo hi | /bin/cat"        ""
vg_nopath "env vide expand HOME"     "echo \$HOME"                    ""
vg_nopath "env vide heredoc"         $'/bin/cat <<EOF\nhello\nEOF'    ""
vg_nopath "env vide redir"           "/bin/echo hi > /tmp/vg_nop.txt" ""
vg_nopath "env vide exit"            "exit 42"                        ""
vg_nopath "PATH vide ls"             "ls"                             "PATH= HOME=/tmp"
vg_nopath "PATH vide pipe"           "ls | cat"                       "PATH= HOME=/tmp"

echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}  RECAP SANS PATH${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}PASS  : $PASS${NC}"
echo -e "${YELLOW}DIFF  : $DIFF${NC}"
echo -e "${GREEN}CLEAN : $CLEAN${NC}"
echo -e "${RED}LEAKS : $LEAKS${NC}"
