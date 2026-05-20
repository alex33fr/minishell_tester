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

VG="valgrind --leak-check=full --show-leak-kinds=all --track-fds=yes --track-origins=yes --suppressions=./readline.supp --error-exitcode=99"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

FAILS=0
WARNS=0
CLEAN=0

vg_test() {
	local desc="$1"
	local input="$2"

	out=$(printf '%s' "$input" | timeout 10 $VG "$MINI" 2>&1)
	code=$?

	definitely=$(echo "$out" | grep -E "definitely lost|indirectly lost" | grep -v "0 bytes")
	reachable=$(echo "$out" | grep -E "still reachable" | grep -v "0 bytes")
	errors=$(echo "$out" | grep "ERROR SUMMARY" | grep -v "0 errors")
	fds=$(echo "$out" | grep "FILE DESCRIPTORS" | grep -v "^==.*FILE DESCRIPTORS: [123] open")

	if [ $code -eq 99 ] || [ -n "$definitely" ] || [ -n "$errors" ]; then
		echo -e "${RED}[FAIL   ] ${desc}${NC}"
		echo -e "  input : $input"
		echo "$out" | grep -E "definitely lost|indirectly lost|ERROR SUMMARY|Invalid|Use of uninitialised" | grep -v "0 bytes" | grep -v "0 errors" | sed 's/^/  /'
		((FAILS++))
	elif [ -n "$reachable" ] || [ -n "$fds" ]; then
		echo -e "${YELLOW}[WARN   ] ${desc}${NC}"
		echo -e "  input : $input"
		echo "$out" | grep -E "still reachable|FILE DESCRIPTORS" | grep -v "0 bytes" | sed 's/^/  /'
		((WARNS++))
	else
		echo -e "${GREEN}[CLEAN  ] ${desc}${NC}"
		((CLEAN++))
	fi
}

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  VALGRIND LEAK TEST SUITE${NC}"
echo -e "${CYAN}================================================================${NC}"

echo -e "\n${CYAN}[PIPES]${NC}"
vg_test "simple pipe"               "echo hello | cat"
vg_test "pipe chain 5"              "echo a | cat | cat | cat | cat"
vg_test "pipe invalid cmds"         "ls | ldkdkd | ls | lk"
vg_test "pipe no right cmd"         "ls |"
vg_test "pipe many invalid"         "lkjh | lkjh | lkjh | lkjh | lkjh"
vg_test "pipe 10x ls"               "ls | ls | ls | ls | ls | ls | ls | ls | ls | ls"

echo -e "\n${CYAN}[REDIRECTIONS]${NC}"
vg_test "redirect out"              "echo hello > /tmp/vg_ms_out.txt"
vg_test "redirect append"           "echo hello >> /tmp/vg_ms_app.txt"
vg_test "redirect in"               "echo hi > /tmp/vg_in.txt"
vg_test "redirect in read"          "cat < /tmp/vg_in.txt"
vg_test "redirect no file"          "> "
vg_test "redirect nonexist <"       "cat < /nonexistent_file_xyz_vg"
vg_test "redirect to dir"           "echo hi > /tmp"
vg_test "redirect no perm"          "echo hi > /root/noperm.txt"
vg_test "multiple redirects"        "echo hi > /tmp/vg_a.txt > /tmp/vg_b.txt"

echo -e "\n${CYAN}[HEREDOC]${NC}"
vg_test "heredoc basic"             $'cat <<EOF\nhello world\nEOF'
vg_test "heredoc empty"             $'cat <<EOF\nEOF'
vg_test "heredoc no terminator"     "cat <<TERM"
vg_test "heredoc with var"          $'cat <<EOF\n$HOME\nEOF'
vg_test "heredoc quoted delim"      $'cat <<"EOF"\n$HOME\nEOF'
vg_test "heredoc pipe after"        $'cat <<EOF | cat\nhello\nEOF'

echo -e "\n${CYAN}[QUOTES]${NC}"
vg_test "double quotes"             'echo "hello world"'
vg_test "single quotes"             "echo 'hello world'"
vg_test "empty double quotes"       'echo ""'
vg_test "empty single quotes"       "echo ''"
vg_test "unclosed double"           'echo "hello'
vg_test "unclosed single"           "echo 'hello"
vg_test "alternating quotes"        "echo 'a'\"b\"'c'\"d\""
vg_test "quote with dollar"         'echo "$HOME"'
vg_test "single no expand"          "echo '\$HOME'"
vg_test "nested single in double"   'echo "hel'"'"'lo"'

echo -e "\n${CYAN}[VARIABLES]${NC}"
vg_test "expand HOME"               "echo \$HOME"
vg_test "expand PATH"               "echo \$PATH"
vg_test "expand empty var"          "echo \$NONEXISTENT_VAR_XYZ"
vg_test "expand dollar alone"       "echo \$"
vg_test "expand in dbl quotes"      'echo "$HOME"'
vg_test "expand ? after true"       "true"
vg_test "expand ? output"           "echo \$?"
vg_test "very long expansion"       "echo \$HOME\$HOME\$HOME\$HOME\$HOME\$HOME\$HOME\$HOME"

echo -e "\n${CYAN}[BUILTINS - echo]${NC}"
vg_test "echo basic"                "echo hello"
vg_test "echo -n"                   "echo -n hello"
vg_test "echo empty"                "echo"
vg_test "echo multi args"           "echo a b c d e f g h"
vg_test "echo empty quotes"         "echo '' \"\""

echo -e "\n${CYAN}[BUILTINS - cd]${NC}"
vg_test "cd no arg"                 "cd"
vg_test "cd /"                      "cd /"
vg_test "cd /tmp"                   "cd /tmp"
vg_test "cd nonexist"               "cd /nonexistent_xyz_abc"
vg_test "cd dotdot"                 "cd .."
vg_test "cd dot"                    "cd ."
vg_test "cd too many args"          "cd /tmp /var"
vg_test "cd empty string"           "cd ''"

echo -e "\n${CYAN}[BUILTINS - export]${NC}"
vg_test "export no args"            "export"
vg_test "export simple"             "export VGTEST=hello"
vg_test "export empty val"          "export VGTEST2="
vg_test "export no val"             "export VGTEST3"
vg_test "export invalid name"       "export 1BADNAME=x"
vg_test "export invalid ="          "export =BADVAL"
vg_test "export quoted val"         "export VGTEST4=\"hello world\""
vg_test "export single quotes val"  "export VGTEST5='hello'"
vg_test "export quotes in val"      "export VGTEST6=\"'inner'\""
vg_test "export empty dbl quotes"   "export VGTEST7=\"\""
vg_test "export empty sgl quotes"   "export VGTEST8=''"
vg_test "export mixed quotes"       "export VGTEST9='a'\"b\"'c'"

echo -e "\n${CYAN}[BUILTINS - unset]${NC}"
vg_test "unset no args"             "unset"
vg_test "unset nonexist"            "unset NONEXIST_VAR_ZZZ"
vg_test "unset existing"            "unset HOME"
vg_test "unset multiple"            "unset HOME PATH"
vg_test "unset invalid"             "unset 1INVALID"

echo -e "\n${CYAN}[BUILTINS - env/pwd]${NC}"
vg_test "env"                       "env"
vg_test "pwd"                       "pwd"
vg_test "pwd with args"             "pwd /tmp"

echo -e "\n${CYAN}[BUILTINS - exit]${NC}"
vg_test "exit 0"                    "exit 0"
vg_test "exit 1"                    "exit 1"
vg_test "exit 42"                   "exit 42"
vg_test "exit no arg"               "exit"
vg_test "exit str"                  "exit abc"
vg_test "exit many args"            "exit 1 2 3"

echo -e "\n${CYAN}[EDGE CASES]${NC}"
vg_test "empty input"               ""
vg_test "only spaces"               "   "
vg_test "cmd not found"             "thiscmddoesnotexist_xyz_abc"
vg_test "very long arg"             "echo $(python3 -c "print('a'*5000)")"
vg_test "many pipes invalid"        "$(python3 -c "print(' | '.join(['invalid_cmd_xyz']*10))")"
vg_test "pipe then redir"           "echo hi | cat > /tmp/vg_pr.txt"
vg_test "semicolon"                 "echo a; echo b"
vg_test "glob star"                 "echo *"
vg_test "tilde"                     "echo ~"
vg_test "slash cmd"                 "/bin/echo hello"
vg_test "null cmd quotes"           "\"\" "
vg_test "dollar question pipe"      "false | echo \$?"

echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}  VALGRIND RECAP${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}CLEAN : $CLEAN${NC}"
echo -e "${YELLOW}WARNS : $WARNS${NC}"
echo -e "${RED}FAILS : $FAILS${NC}"
