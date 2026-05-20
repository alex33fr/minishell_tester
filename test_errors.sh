#!/bin/bash

# Usage: bash test_errors.sh [./chemin/minishell] [--valgrind]
#   sans flag  : comparaison bash vs minishell (exit code + stdout + stderr)
#   --valgrind : idem + détection de fuites mémoire sur chaque test

cd "$(dirname "$0")"

MINI="${MINI_BIN:-./minishell}"
USE_VG=0
for _arg in "$@"; do
	if [[ "$_arg" == "--valgrind" ]]; then USE_VG=1
	elif [[ "$_arg" == "./"* || "$_arg" == "/"* ]] && [[ -z "$MINI_BIN" ]]; then MINI="$_arg"
	fi
done
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

VG="valgrind --leak-check=full --show-leak-kinds=all --track-fds=yes \
    --track-origins=yes --suppressions=./readline.supp --error-exitcode=42 -q"

PASS=0
FAIL=0
LEAKS=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

normalize() {
	sed 's/^bash: line [0-9]*: //' | sed 's/^minishell: //'
}

check() {
	local desc="$1"
	local input="$2"

	mini_out=$(printf '%s' "$input" | timeout 5 "$MINI" 2>/tmp/mini_err_$$)
	mini_exit=$?
	mini_err=$(cat /tmp/mini_err_$$ | normalize)

	bash_out=$(printf '%s' "$input" | timeout 5 bash --norc --noprofile 2>/tmp/bash_err_$$)
	bash_exit=$?
	bash_err=$(cat /tmp/bash_err_$$ | normalize)

	rm -f /tmp/mini_err_$$ /tmp/bash_err_$$

	local ok=1
	local reasons=()

	[ "$mini_exit" != "$bash_exit" ] && ok=0 && reasons+=("exit: mini=${mini_exit} bash=${bash_exit}")
	[ "$mini_err"  != "$bash_err"  ] && ok=0 && reasons+=("stderr differ")
	[ "$mini_out"  != "$bash_out"  ] && ok=0 && reasons+=("stdout differ")

	# valgrind si demandé
	local vg_status=""
	if [ $USE_VG -eq 1 ]; then
		vg_out=$(printf '%s' "$input" | timeout 10 $VG "$MINI" 2>/tmp/vg_err_$$)
		vg_code=$?
		vg_leak=$(grep -E "definitely lost|indirectly lost|still reachable" /tmp/vg_err_$$ | grep -v "0 bytes")
		vg_err=$(grep "ERROR SUMMARY" /tmp/vg_err_$$ | grep -v "0 errors")
		rm -f /tmp/vg_err_$$
		if [ $vg_code -eq 42 ] || [ -n "$vg_leak" ] || [ -n "$vg_err" ]; then
			vg_status=" ${RED}[LEAK]${NC}"
			((LEAKS++))
		fi
	fi

	if [ $ok -eq 1 ]; then
		echo -e "${GREEN}[OK  ]${NC}${vg_status} ${desc}"
		((PASS++))
	else
		echo -e "${RED}[FAIL]${NC}${vg_status} ${desc}"
		for r in "${reasons[@]}"; do
			echo -e "  ${YELLOW}$r${NC}"
		done
		[ "$mini_err" != "$bash_err" ] && \
			echo -e "  stderr mini : $(echo "$mini_err" | head -2)" && \
			echo -e "  stderr bash : $(echo "$bash_err" | head -2)"
		[ "$mini_out" != "$bash_out" ] && \
			echo -e "  stdout mini : $(echo "$mini_out" | head -2)" && \
			echo -e "  stdout bash : $(echo "$bash_out" | head -2)"
		((FAIL++))
	fi
}

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  EXIT CODE + MESSAGE — COMPARAISON AVEC BASH${NC}"
echo -e "${CYAN}================================================================${NC}"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[1] COMMANDES INTROUVABLES${NC}"
# ─────────────────────────────────────────────
check "cmd inexistant simple"       "thiscmddoesnotexist"
check "cmd inexistant avec args"    "thiscmddoesnotexist arg1 arg2"
check "./relatif inexistant"        "./nonexistent_xyz"
check "chemin absolu inexistant"    "/nonexistent_xyz"
check "cmd dans pipe gauche"        "thiscmd | cat"
check "cmd dans pipe droit"         "echo hi | thiscmd"
check "cmd dans pipe milieu"        "echo hi | thiscmd | cat"
check "tous invalid dans pipe"      "aaa | bbb | ccc"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[2] REDIRECTIONS — ERREURS${NC}"
# ─────────────────────────────────────────────
check "< fichier inexistant"        "cat < /nonexistent_xyz_abc"
check "> sans permission"           "echo hi > /root/noperm_xyz.txt"
check ">> sans permission"          "echo hi >> /root/noperm_xyz.txt"
check "> dossier"                   "echo hi > /tmp"
check "< dossier"                   "cat < /tmp"
check "> sans fichier"              "> "
check "< sans fichier"              "< "
check ">> sans fichier"             ">> "
check "<< sans délimiteur"          "cat <<"
check "> /dev/full"                 "echo hi > /dev/full"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[3] SYNTAXE — ERREURS${NC}"
# ─────────────────────────────────────────────
check "pipe sans gauche"            "| ls"
check "pipe sans droite"            "ls |"
check "double pipe"                 "ls || ls"
check "guillemet double non fermé"  'echo "hello'
check "guillemet simple non fermé"  "echo 'hello"
check "triple pipe"                 "ls ||| ls"
check "pipe vide enchaîné"          "| | |"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[4] BUILTIN cd — ERREURS${NC}"
# ─────────────────────────────────────────────
check "cd inexistant"               "cd /nonexistent_xyz_abc"
check "cd trop d'arguments"         "cd /tmp /var"
check "cd vide string"              "cd ''"
check "cd sans arg"                 "cd"
check "cd sans HOME"                "unset HOME"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[5] BUILTIN export — ERREURS${NC}"
# ─────────────────────────────────────────────
check "export nom commence par chiffre"   "export 1BAD=val"
check "export = en tête"                  "export =badval"
check "export nom avec tiret"             "export bad-name=val"
check "export nom avec espace"            "export bad name=val"
check "export nom avec @"                 "export bad@name=val"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[6] BUILTIN unset — ERREURS${NC}"
# ─────────────────────────────────────────────
check "unset nom invalide chiffre"        "unset 1BAD"
check "unset nom invalide tiret"          "unset bad-name"
check "unset nom invalide @"              "unset bad@name"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[7] BUILTIN exit — ERREURS${NC}"
# ─────────────────────────────────────────────
check "exit arg non numérique"      "exit abc"
check "exit trop d'arguments"       "exit 1 2 3"
check "exit arg alphanumérique"     "exit 1abc"
check "exit sans arg"               "exit"
check "exit 0"                      "exit 0"
check "exit 1"                      "exit 1"
check "exit 42"                     "exit 42"
check "exit 126"                    "exit 126"
check "exit 127"                    "exit 127"
check "exit 128"                    "exit 128"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[8] PERMISSIONS D'EXÉCUTION${NC}"
# ─────────────────────────────────────────────
touch /tmp/ms_noperm_exec.sh && chmod 000 /tmp/ms_noperm_exec.sh
check "exec sans permission"        "/tmp/ms_noperm_exec.sh"
chmod 644 /tmp/ms_noperm_exec.sh
check "exec non exécutable (644)"   "/tmp/ms_noperm_exec.sh"
rm -f /tmp/ms_noperm_exec.sh

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[9] CODES ERREUR SPÉCIAUX${NC}"
# ─────────────────────────────────────────────
check "exit code cmd inexistant"    "thiscmdnotfound; echo exitwas:\$?"
check "exit code permission denied" "cat /root/shadow_xyz 2>/dev/null; echo exitwas:\$?"
check "exit code pipe droit fail"   "true | false; echo exitwas:\$?"
check "exit code pipe gauche fail"  "false | true; echo exitwas:\$?"
check "exit code last pipe"         "false | false | true; echo exitwas:\$?"
check "exit code syntax error"      "ls |; echo after"
check "exit code redir fail"        "cat < /nonexistent_xyz; echo exitwas:\$?"

# ─────────────────────────────────────────────
echo -e "\n${BOLD}[10] EXPORT + QUOTES — valeur préservée${NC}"
# ─────────────────────────────────────────────
# Utilise newline comme séparateur (pas &&)
# La fonction check passe l'input brut, les newlines servent de séparateurs

# Cas de base — doit marcher
check "export val simple"                  $'export _A=hello\necho $_A'
check "export val double quotes"           $'export _A="hello"\necho $_A'
check "export val single quotes"           $'export _A='"'"'hello'"'"'\necho $_A'
check "export val vide dbl"                $'export _A=""\necho $_A'
check "export val vide sgl"                $'export _A='"'"''"'"'\necho $_A'

# Singles à l'intérieur des doubles — le vrai bug
check "export dbl wraps singles vides"     $'export _A="\'\'"\necho $_A'
check "export dbl wraps single mot"        $'export _A="\'hello\'"\necho $_A'
check "export dbl single ouvrant seul"     $'export _A="\'"\necho $_A'
check "export dbl single fermant seul"     $'export _A="\'"\necho $_A'
check "export dbl singles multiples"       $'export _A="\'a\'b\'c\'"\necho $_A'
check "export dbl singles + texte"         $'export _A="hello\'world\'"\necho $_A'
check "export dbl singles vides + texte"   $'export _A="hello\'\'world"\necho $_A'

# Avec expansion de variable à l'intérieur
check "export dbl singles vides + \$USER" $'export _A="\'\'$USER\'\'"\necho $_A'
check "export dbl \$USER entre singles"    $'export _A="\'$USER\'"\necho $_A'
check "export dbl \$HOME entre singles"    $'export _A="\'$HOME\'"\necho $_A'
check "export dbl singles + \$USER milieu" $'export _A="\'\'$USER"\necho $_A'
check "export dbl \$USER + singles fin"    $'export _A="$USER\'\'"\necho $_A'
check "export sgl contient \$USER"         $'export _A='"'"'$USER'"'"'\necho $_A'
check "export sgl contient dbl quotes"     $'export _A='"'"'""'"'"'\necho $_A'
check "export sgl contient dbl mot"        $'export _A='"'"'"hello"'"'"'\necho $_A'

# Doubles à l'intérieur des singles
check "export sgl wraps doubles vides"     $'export _A='"'"'""'"'"'\necho $_A'
check "export sgl wraps double mot"        $'export _A='"'"'"hello"'"'"'\necho $_A'
check "export sgl dbl ouvrant seul"        $'export _A='"'"'"'"'"'\necho $_A'

# Alternance quotes
check "export alternance sgl dbl"          $'export _A='"'"'a'"'"'"b"'"'"'c'"'"'\necho $_A'
check "export alternance dbl sgl"          $'export _A="a"'"'"'b'"'"'"c"\necho $_A'
check "export mix sans séparateur"         $'export _A="hello"'"'"'world'"'"'\necho $_A'

# Cas avancés avec $? et $USER
check "export val avec \$?"                $'true\nexport _A="exit:$?"\necho $_A'
check "export sgl + dbl + var"             $'export _A='"'"'prefix'"'"'"$USER"'"'"'suffix'"'"'\necho $_A'
check "export vide puis réassigner"        $'export _A=""\nexport _A="hello"\necho $_A'
check "export puis unset puis echo"        $'export _A="hello"\nunset _A\necho $_A'
check "export overwrite avec quotes"       $'export _A="\'old\'"\nexport _A="\'new\'"\necho $_A'

# Séquences de singles dans doubles — combinatoire
check "export 4 singles vides"             $'export _A="\'\'\'\'"\necho $_A'
check "export singles intercalés texte"    $'export _A="a\'b\'c\'d"\necho $_A'
check "export quote dans valeur sans ="    $'export _A\nexport _A="test"\necho $_A'

echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}  RECAP${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}PASS  : $PASS${NC}"
echo -e "${RED}FAIL  : $FAIL${NC}"
[ $USE_VG -eq 1 ] && echo -e "${RED}LEAKS : $LEAKS${NC}"
[ $USE_VG -eq 0 ] && echo -e "${YELLOW}(relancer avec --valgrind pour détecter les fuites)${NC}"
