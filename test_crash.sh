#!/bin/bash

cd "$(dirname "$0")"
MINI="${1:-${MINI_BIN:-./minishell}}"
if [[ "$MINI" == -* ]]; then MINI="${MINI_BIN:-./minishell}"; fi
if [ ! -x "$MINI" ]; then
	echo "ERROR — binaire introuvable : $MINI" >&2; exit 1
fi
PASS=0
FAIL=0
CRASH=0
MISMATCH=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

results=()

run_test() {
	local desc="$1"
	local input="$2"

	mini_out=$(printf '%s' "$input" | timeout 5 "$MINI" 2>&1)
	mini_exit=$?
	bash_out=$(printf '%s' "$input" | timeout 5 bash --norc --noprofile 2>&1)
	bash_exit=$?

	if [ $mini_exit -eq 124 ]; then
		echo -e "${RED}[TIMEOUT] ${desc}${NC}"
		echo -e "  input: $(echo "$input" | head -1)"
		results+=("TIMEOUT|$desc|$input")
		((CRASH++))
		return
	fi

	if [ $mini_exit -ge 134 ] || [ $mini_exit -eq 139 ] || [ $mini_exit -eq 134 ]; then
		echo -e "${RED}[CRASH  ] ${desc} (exit=$mini_exit)${NC}"
		echo -e "  input: $input"
		results+=("CRASH|$desc|$input|exit=$mini_exit")
		((CRASH++))
		return
	fi

	if [ "$mini_out" != "$bash_out" ] || [ "$mini_exit" != "$bash_exit" ]; then
		echo -e "${YELLOW}[DIFF   ] ${desc}${NC}"
		echo -e "  input  : $input"
		echo -e "  mini   : $(echo "$mini_out" | head -3) [exit=$mini_exit]"
		echo -e "  bash   : $(echo "$bash_out" | head -3) [exit=$bash_exit]"
		results+=("DIFF|$desc|$input|mini=$mini_exit bash=$bash_exit")
		((MISMATCH++))
	else
		echo -e "${GREEN}[OK     ] ${desc}${NC}"
		((PASS++))
	fi
}

run_crash_only() {
	local desc="$1"
	local input="$2"

	mini_out=$(printf '%s' "$input" | timeout 5 "$MINI" 2>&1)
	mini_exit=$?

	if [ $mini_exit -eq 124 ]; then
		echo -e "${RED}[TIMEOUT] ${desc}${NC}"
		echo -e "  input: $input"
		results+=("TIMEOUT|$desc|$input")
		((CRASH++))
	elif [ $mini_exit -ge 134 ] || [ $mini_exit -eq 139 ]; then
		echo -e "${RED}[CRASH  ] ${desc} (exit=$mini_exit)${NC}"
		echo -e "  input: $input"
		results+=("CRASH|$desc|$input|exit=$mini_exit")
		((CRASH++))
	else
		echo -e "${GREEN}[OK     ] ${desc} (exit=$mini_exit)${NC}"
		((PASS++))
	fi
}

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  MINISHELL CRASH & DIFF TEST SUITE${NC}"
echo -e "${CYAN}================================================================${NC}"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[1] PIPES${NC}"
# ─────────────────────────────────────────────
run_test "simple pipe"           "echo hello | cat"
run_test "triple pipe"           "echo a | cat | cat"
run_test "pipe chain 6"          "ls | cat | cat | cat | cat | cat"
run_test "pipe with invalid cmd" "ls | ldkdkd | ls | ls | ls | dd | lk"
run_test "pipe no left"          "| ls"
run_test "pipe no right"         "ls |"
run_test "double pipe"           "ls || ls"
run_test "pipe empty string"     "echo '' | cat"
run_test "pipe newline"          'printf "a\nb\nc" | wc -l'
run_test "pipe to grep"          "echo hello | grep hello"
run_test "pipe exit code"        "ls /nonexist 2>/dev/null | echo done"
run_test "pipe many invalid"     "lkjh | lkjh | lkjh | lkjh | lkjh"
run_crash_only "pipe 20x"        "$(python3 -c "print(' | '.join(['ls']*20))")"
run_crash_only "pipe 50x"        "$(python3 -c "print(' | '.join(['ls']*50))")"
run_test "pipe sleep timeout"    "echo x | cat"
run_test "cat /dev/null pipe"    "cat /dev/null | ls"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[2] REDIRECTIONS${NC}"
# ─────────────────────────────────────────────
run_test "redirect out"          "echo hello > /tmp/ms_test_out.txt && cat /tmp/ms_test_out.txt"
run_test "redirect append"       "echo a >> /tmp/ms_app.txt && echo b >> /tmp/ms_app.txt && cat /tmp/ms_app.txt"
run_test "redirect in"          "echo hello > /tmp/ms_in.txt && cat < /tmp/ms_in.txt"
run_test "redirect no file >"   "> "
run_test "redirect no file <"   "< "
run_test "redirect no file >>"  ">> "
run_test "redirect chain"       "> /tmp/ms_a.txt > /tmp/ms_b.txt echo hello"
run_test "redir out then pipe"   "echo hello > /tmp/ms_rp.txt | cat"
run_test "redirect nonexist <"   "cat < /nonexistent_file_xyz"
run_test "redirect /dev/null"    "echo hello > /dev/null"
run_test "multiple > same cmd"   "echo hi > /tmp/ms_m1.txt > /tmp/ms_m2.txt"
run_test "redirect to dir"       "echo hi > /tmp"
run_test "no perm redirect"      "echo hi > /root/noperm.txt"
run_crash_only "redir chain 10x" "$(python3 -c "print(' '.join(['> /tmp/ms_chain.txt']*10) + ' echo hi')")"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[3] HEREDOC${NC}"
# ─────────────────────────────────────────────
run_crash_only "heredoc basic"   $'cat <<EOF\nhello\nEOF'
run_crash_only "heredoc no term" "cat <<EOF"
run_crash_only "heredoc empty"   $'cat <<EOF\nEOF'
run_crash_only "heredoc nested"  $'cat <<A\ncat <<B\nB\nA'
run_crash_only "heredoc var"     $'cat <<EOF\n$HOME\nEOF'
run_crash_only "heredoc quoted"  $'cat <<"EOF"\n$HOME\nEOF'
run_crash_only "heredoc pipe"    $'cat <<EOF | cat\nhello\nEOF'
run_crash_only "heredoc multi"   $'cat <<A <<B\nhello\nA\nworld\nB'

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[4] QUOTES${NC}"
# ─────────────────────────────────────────────
run_test "double quotes basic"   'echo "hello world"'
run_test "single quotes basic"   "echo 'hello world'"
run_test "mixed quotes"          "echo \"hello\" 'world'"
run_test "unclosed double quote" 'echo "hello'
run_test "unclosed single quote" "echo 'hello"
run_test "empty double quotes"   'echo ""'
run_test "empty single quotes"   "echo ''"
run_test "quote with dollar"     'echo "$HOME"'
run_test "single quote no expand" "echo '\$HOME'"
run_test "nested single in double" 'echo "hel'"'"'lo"'
run_test "double in single"      "echo 'hel\"lo'"
run_test "quote with pipe"       'echo "a|b"'
run_test "quote with redirect"   'echo "a>b"'
run_test "many quotes"           "echo \"\" \"\" \"\" \"\" \"\""
run_test "quote with newline"    'echo "line1\nline2"'
run_test "alternating quotes"    "echo 'a'\"b\"'c'\"d\""

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[5] VARIABLES / EXPANSION${NC}"
# ─────────────────────────────────────────────
run_test "expand HOME"           "echo \$HOME"
run_test "expand PATH"           "echo \$PATH"
run_test "expand empty var"      "echo \$NONEXISTENT_VAR_XYZ"
run_test "expand ?"              "true; echo \$?"
run_test "expand ? false"        "false; echo \$?"
run_test "expand in quotes"      'echo "$HOME"'
run_test "no expand single"      "echo '\$HOME'"
run_test "dollar alone"          "echo \$"
run_test "dollar digit"          "echo \$1"
run_test "dollar star"           "echo \$*"
run_test "double dollar"         "echo \$\$"
run_test "expand concat"         "echo \${HOME}x"
run_test "var after pipe"        "echo hello | echo \$HOME"
run_test "expand in heredoc"     $'cat <<EOF\n$HOME\nEOF'
run_test "expand ? in pipe"      "false | echo \$?"
run_test "expand nonexist"       "echo \$ZZZNOPE"
run_crash_only "very long var"   "echo $(python3 -c "print('\$A'*1000)")"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[6] BUILTIN: echo${NC}"
# ─────────────────────────────────────────────
run_test "echo basic"            "echo hello"
run_test "echo -n"               "echo -n hello"
run_test "echo -n -n"            "echo -n -n"
run_test "echo multiple args"    "echo a b c d e"
run_test "echo empty"            "echo"
run_test "echo newlines"         "echo -n ''"
run_test "echo special chars"    "echo 'hello\tworld'"
run_test "echo dollar"           "echo \$?"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[7] BUILTIN: cd${NC}"
# ─────────────────────────────────────────────
run_test "cd home"               "cd && pwd"
run_test "cd ~"                  "cd ~ && pwd"
run_test "cd /"                  "cd / && pwd"
run_test "cd nonexist"           "cd /nonexistent_xyz_abc"
run_test "cd no arg"             "cd"
run_test "cd -"                  "cd /tmp && cd - && pwd"
run_test "cd too many args"      "cd /tmp /tmp"
run_test "cd empty string"       "cd ''"
run_test "cd dot"                "cd ."
run_test "cd dotdot"             "cd .."

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[8] BUILTIN: export${NC}"
# ─────────────────────────────────────────────
run_test "export basic"          "export TESTVAR=hello && echo \$TESTVAR"
run_test "export no value"       "export TESTVAR2 && echo \$TESTVAR2"
run_test "export empty"          "export TESTVAR3= && echo \$TESTVAR3"
run_test "export invalid name"   "export 1BADNAME=x"
run_test "export invalid ="      "export =BADVAL"
run_test "export with quotes"    "export A=\"hello world\" && echo \$A"
run_test "export single in dbl"  "export B=\"'hello'\" && echo \$B"
run_test "export dbl in single"  "export C='\"hello\"' && echo \$C"
run_test "export complex quotes" "export D=\"'\"'\"'\" && echo \$D"
run_test "export empty quotes"   "export E=\"\" && echo \$E"
run_test "export single empty"   "export F='' && echo \$F"
run_test "export mixed quotes"   "export G='a'\"b\"'c' && echo \$G"
run_test "export overwrite"      "export H=1 && export H=2 && echo \$H"
run_test "export no args"        "export"
run_test "export spaces"         "export I=hello && export I=hello world"
run_test "export then unset"     "export J=42 && unset J && echo \$J"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[9] BUILTIN: unset${NC}"
# ─────────────────────────────────────────────
run_test "unset basic"           "export K=1 && unset K && echo \$K"
run_test "unset nonexist"        "unset NONEXIST_VAR_ZZZ"
run_test "unset no args"         "unset"
run_test "unset multiple"        "export L=1 && export M=2 && unset L M && echo \$L\$M"
run_test "unset invalid"         "unset 1INVALID"
run_test "unset HOME"            "unset HOME && echo \$HOME"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[10] BUILTIN: env${NC}"
# ─────────────────────────────────────────────
run_crash_only "env basic"       "env"
run_crash_only "env with args"   "env ls"
run_crash_only "env pipe"        "env | grep HOME"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[11] BUILTIN: pwd${NC}"
# ─────────────────────────────────────────────
run_test "pwd basic"             "pwd"
run_test "pwd after cd"          "cd /tmp && pwd"
run_test "pwd with args"         "pwd /tmp"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[12] BUILTIN: exit${NC}"
# ─────────────────────────────────────────────
run_crash_only "exit 0"          "exit 0"
run_crash_only "exit 1"          "exit 1"
run_crash_only "exit 42"         "exit 42"
run_crash_only "exit 255"        "exit 255"
run_crash_only "exit 256"        "exit 256"
run_crash_only "exit -1"         "exit -1"
run_crash_only "exit no arg"     "exit"
run_crash_only "exit str"        "exit abc"
run_crash_only "exit many args"  "exit 1 2 3"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[13] EDGE CASES / DINGUES${NC}"
# ─────────────────────────────────────────────
run_crash_only "empty cmd"              ""
run_crash_only "only spaces"            "   "
run_crash_only "only semicolon"         ";"
run_crash_only "only newline"           $'\n'
run_test "cmd with spaces"              "   echo   hello   "
run_crash_only "very long cmd"          "$(python3 -c "print('echo ' + 'a'*10000)")"
run_crash_only "many args"              "$(python3 -c "print('echo ' + ' '.join(['arg']*500))")"
run_test "null byte in var"             "echo hello"
run_crash_only "semicolons"             "echo a; echo b; echo c"
run_crash_only "ampersand"              "echo a & echo b"
run_crash_only "backslash"             "echo a\ b"
run_crash_only "tilde expansion"        "echo ~"
run_crash_only "glob star"              "echo *"
run_test "slash in cmd"                 "/bin/echo hello"
run_test "relative path cmd"            "./minishell --version"
run_crash_only "null cmd"               "\"\" "
run_crash_only "just dollar"            "\$"
run_crash_only "pipe then redirect"     "echo hi | > /tmp/ms_pr.txt cat"
run_crash_only "redirect then pipe"     "> /tmp/ms_rp2.txt echo hi | cat"
run_crash_only "multiple redirects"     "echo hi > /tmp/a.txt < /tmp/a.txt >> /tmp/a.txt"
run_crash_only "cmd not found"          "thiscmddoesnotexist_xyz_abc"
run_crash_only "empty pipe chain"       "| | | |"
run_crash_only "mixed op chaos"         "echo a | echo b > /tmp/ms_chaos.txt | cat"
run_crash_only "env=val cmd"            "HOME=/tmp pwd"
run_crash_only "quoted pipe"            "echo 'a | b'"
run_crash_only "dollar question pipe"   "false | echo \$?"

# ─────────────────────────────────────────────
echo -e "\n${BLUE}[14] EXPORT QUOTES COMPARISON (known bug)${NC}"
# ─────────────────────────────────────────────
echo -e "${CYAN}--- Testing export with complex quotes vs bash ---${NC}"

tests_export=(
	"export X=\"'hello'\" && echo \$X"
	"export X='\"hello\"' && echo \$X"
	"export X=\"'\"'\"'\" && echo \$X"
	"export X=\"''\" && echo \$X"
	"export X='\"\"' && echo \$X"
	"export X=\"'a'b'c'\" && echo \$X"
	"export X=\"'\" && echo \$X"
	"export X='\'' && echo \$X"
)

for t in "${tests_export[@]}"; do
	mini_out=$(printf '%s' "$t" | timeout 5 "$MINI" 2>&1)
	bash_out=$(printf '%s' "$t" | timeout 5 bash --norc --noprofile 2>&1)
	if [ "$mini_out" != "$bash_out" ]; then
		echo -e "${YELLOW}[EXPORT DIFF]${NC} input: $t"
		echo -e "  mini : '$mini_out'"
		echo -e "  bash : '$bash_out'"
	else
		echo -e "${GREEN}[EXPORT OK ]${NC} $t"
	fi
done

# ─────────────────────────────────────────────
echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}  RECAP${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}PASS    : $PASS${NC}"
echo -e "${YELLOW}DIFF    : $MISMATCH${NC}"
echo -e "${RED}CRASH   : $CRASH${NC}"
echo ""

if [ ${#results[@]} -gt 0 ]; then
	echo -e "${RED}Issues détectées :${NC}"
	for r in "${results[@]}"; do
		type=$(echo "$r" | cut -d'|' -f1)
		desc=$(echo "$r" | cut -d'|' -f2)
		extra=$(echo "$r" | cut -d'|' -f4)
		echo -e "  [$type] $desc $extra"
	done
fi
