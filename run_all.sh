#!/bin/bash

# Lance toute la suite de tests avec valgrind (make re automatique)
# Usage: bash run_all.sh [N|N-M] [-e [N|N-M]] [-c] [-l] [-w]
#   5        = catégorie 5 uniquement              ex: ./run_all.sh 5
#   5-7      = catégories 5 à 7                   ex: ./run_all.sh 5-7
#   -e N     = catégorie N + afficher FAIL         ex: -e 5
#   -e N-M   = catégories N à M + afficher FAIL   ex: -e 5-7
#   -e       = toutes catégories, afficher FAIL
#   -c = CRASH   -l = LEAK   -w = WARN
#   combinable: 8 -l   -e 8 -l   5-7 -cl   -eclw   etc.
#   (sans flag = tout afficher)
# Logs : logs_full_test.txt (écrasé à chaque run)

cd "$(dirname "$0")"

LOGFILE="./logs_full_test.txt"
> "$LOGFILE"

# Compilation systématique avant chaque run
echo "================================================================"
echo "  Compilation (make re)..."
echo "================================================================"
if ! make -C .. re 2>&1; then
	echo ""
	echo "================================================================"
	echo "  ERROR — make re a échoué, tests annulés"
	echo "================================================================"
	exit 1
fi
echo ""

MINI="${MINI_BIN:-../minishell}"
if [ ! -x "$MINI" ]; then
	echo "================================================================"
	echo "  ERROR — binaire introuvable après compilation : $MINI"
	echo "================================================================"
	exit 1
fi

# Compile fake_readline.so pour intercepter readline() et imposer un prompt fixe "MINIT: "
# Sans ça, le prompt du minishell pollue stdout et les tests échouent tous.
_TDIR="$(cd "$(dirname "$0")" && pwd)"
_FAKE_RL="${_TDIR}/fake_readline.so"
if [ ! -f "$_FAKE_RL" ]; then
	if gcc -shared -fPIC -o "$_FAKE_RL" "${_TDIR}/fake_readline.c" -ldl 2>/dev/null; then
		echo "[INFO] fake_readline.so compilé avec succès"
	else
		echo "[WARN] fake_readline.so compilation échouée — détection dynamique du prompt"
		_FAKE_RL=""
	fi
fi
if [ -n "$_FAKE_RL" ] && [ -f "$_FAKE_RL" ]; then
	export LD_PRELOAD="$_FAKE_RL"
	_MINI_PROMPT="MINIT: "
else
	# Fallback : le prompt se termine par "exit" (via printf("exit\n") sur EOF)
	_raw=$(printf '' | timeout 2 "$MINI" 2>/dev/null)
	_MINI_PROMPT="${_raw%exit}"
fi

# Crée readline.supp si absent
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
	echo "[INFO] readline.supp créé automatiquement"
fi

VG="valgrind --leak-check=full --show-leak-kinds=all --track-fds=yes \
    --track-origins=yes --suppressions=$PWD/readline.supp \
    --error-exitcode=99 -q"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

TOTAL_PASS=0
TOTAL_WARN=0
TOTAL_FAIL=0
TOTAL_LEAK=0
TOTAL_CRASH=0
TEST_NUM=0
CURRENT_SECTION=""
SKIP_SECTION=0

# ─── Parse args ──────────────────────────────────────────────────────
# -e N     = catégorie N uniquement
# -e N-M   = catégories N à M
# -e       = toutes les catégories, afficher seulement FAIL
# -c=CRASH  -l=LEAK  -w=WARN  (combinables : -cl -eclw …)
SHOW_E=0; SHOW_C=0; SHOW_L=0; SHOW_W=0
SEC_FROM=1; SEC_TO=99
i=1
while [ $i -le $# ]; do
	arg="${!i}"
	if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
		# bare range: ./run_all.sh 5-7
		SEC_FROM=${BASH_REMATCH[1]}; SEC_TO=${BASH_REMATCH[2]}
	elif [[ "$arg" =~ ^([0-9]+)$ ]]; then
		# bare number: ./run_all.sh 5
		SEC_FROM=$arg; SEC_TO=$arg
	elif [[ "$arg" == "-e" ]]; then
		SHOW_E=1
		ni=$((i + 1)); next="${!ni:-}"
		if [[ "$next" =~ ^([0-9]+)-([0-9]+)$ ]]; then
			SEC_FROM=${BASH_REMATCH[1]}; SEC_TO=${BASH_REMATCH[2]}; i=$((i + 1))
		elif [[ "$next" =~ ^([0-9]+)$ ]]; then
			SEC_FROM=$next; SEC_TO=$next; i=$((i + 1))
		fi
	else
		stripped="${arg#-}"; stripped="${stripped#-}"
		[[ "$stripped" == *e* ]] && SHOW_E=1
		[[ "$stripped" == *c* ]] && SHOW_C=1
		[[ "$stripped" == *l* ]] && SHOW_L=1
		[[ "$stripped" == *w* ]] && SHOW_W=1
	fi
	i=$((i + 1))
done
if [ $SHOW_E -eq 0 ] && [ $SHOW_C -eq 0 ] && [ $SHOW_L -eq 0 ] && [ $SHOW_W -eq 0 ]; then
	SHOW_E=1; SHOW_C=1; SHOW_L=1; SHOW_W=1
fi

if [ "$SEC_FROM" -eq 1 ] && [ "$SEC_TO" -ge 34 ]; then
	TOTAL_TESTS=$(grep -cE '^\s*(check|check_ei|vcheck|sigtest)\s+"' "$0")
else
	TOTAL_TESTS=$(awk -v from="$SEC_FROM" -v to="$SEC_TO" '
		/section[[:space:]].*\[[0-9]+\]/ { s=$0; sub(/.*\[/,"",s); sub(/\].*/,"",s); cur=s+0 }
		/^[[:space:]]*(check|check_ei|vcheck|sigtest)[[:space:]]+"/ { if(cur>=from&&cur<=to) c++ }
		END { print c+0 }
	' "$0")
fi

normalize() {
	sed 's/^bash: line [0-9]*: //' | sed "s/^$(basename "$MINI"): //"
}

strip_prompt() {
	[ -z "$_MINI_PROMPT" ] && cat && return
	# Supprime toutes les occurrences du prompt + la ligne de commande echo'd.
	# perl -0777 slurpe l'entrée entière pour gérer le cas où le prompt apparaît
	# en milieu de ligne (ex: "hiMINIT: next_cmd\n" quand printf n'ajoute pas de \n).
	perl -0777 -pe 's/\Q'"$_MINI_PROMPT"'\E[^\n]*\n?//g'
}

# Retourne 0-100 : % de mots de $1 présents dans $2
stderr_sim() {
	local a="$1" b="$2"
	[ "$a" = "$b" ] && echo 100 && return
	[ -z "$a" ] && [ -z "$b" ] && echo 100 && return
	[ -z "$a" ] || [ -z "$b" ] && echo 0 && return
	local total common
	total=$(echo "$a" | tr -cs '[:alnum:]_.-' '\n' | grep -v '^$' | sort -u | wc -l)
	[ "$total" -eq 0 ] && echo 100 && return
	common=$(comm -12 \
		<(echo "$a" | tr -cs '[:alnum:]_.-' '\n' | grep -v '^$' | sort -u) \
		<(echo "$b" | tr -cs '[:alnum:]_.-' '\n' | grep -v '^$' | sort -u) \
		| wc -l)
	echo $(( common * 100 / total ))
}

_progress() {
	local pct=0
	[ "$TOTAL_TESTS" -gt 0 ] && pct=$(( TEST_NUM * 100 / TOTAL_TESTS ))
	printf "\r${CYAN}[%3d%%]${NC} %d/%d  " "$pct" "$TEST_NUM" "$TOTAL_TESTS"
}

should_display() {
	local fail=$1 warn=$2 leak=$3 crash=$4
	if [ $fail -eq 0 ] && [ $warn -eq 0 ] && [ $leak -eq 0 ] && [ $crash -eq 0 ]; then
		[ $SHOW_E -eq 1 ] && [ $SHOW_C -eq 1 ] && [ $SHOW_L -eq 1 ] && [ $SHOW_W -eq 1 ] && return 0
		return 1
	fi
	[ $fail  -eq 1 ] && [ $SHOW_E -eq 1 ] && return 0
	[ $warn  -eq 1 ] && [ $SHOW_W -eq 1 ] && return 0
	[ $leak  -eq 1 ] && [ $SHOW_L -eq 1 ] && return 0
	[ $crash -eq 1 ] && [ $SHOW_C -eq 1 ] && return 0
	return 1
}

# Écriture dans le log (texte propre, sans codes ANSI)
log() { printf '%s\n' "$*" >> "$LOGFILE"; }

log_header() {
	log ""
	log "════════════════════════════════════════════════════"
	log "  $1"
	log "════════════════════════════════════════════════════"
}

log_test() {
	local num="$1" desc="$2" status="$3" input="$4"
	local mini_o="$5" mini_e="$6" mini_x="$7"
	local bash_o="$8" bash_e="$9" bash_x="${10}"
	local leak_info="${11}"

	log ""
	log "Test ${num}: ${desc}  [${status}]"
	log "\$> $(echo "$input" | head -1)"
	if [ "$status" = "OK" ] || [ "$status" = "OK+LEAK" ]; then
		[ -n "$mini_o" ] && log "  sortie : $(echo "$mini_o" | head -3 | tr '\n' '|' | sed 's/|$//')"
	else
		log "  minishell [exit=${mini_x}]:"
		[ -n "$mini_o" ] && log "    stdout : $(echo "$mini_o" | head -3 | tr '\n' '↵ ' | sed 's/ $//')"
		[ -n "$mini_e" ] && log "    stderr : $(echo "$mini_e" | head -3 | tr '\n' '↵ ' | sed 's/ $//')"
		[ "$mini_x" != "$bash_x" ] && log "  !! exit code différent : minishell=${mini_x}  bash=${bash_x}"
		[ "$mini_o" != "$bash_o" ] && log "  !! stdout différent"
		[ "$mini_e" != "$bash_e" ] && log "  !! stderr différent"
	fi
	if [ -n "$leak_info" ]; then
		log "  --- VALGRIND OUTPUT COMPLET ---"
		while IFS= read -r line; do
			log "    $line"
		done <<< "$leak_info"
		log "  --- FIN VALGRIND ---"
	fi
}

# ─────────────────────────────────────────────
# Comparaison bash vs mini + valgrind
check() {
	local desc="$1"
	local input="$2"
	[ $SKIP_SECTION -eq 1 ] && return
	((TEST_NUM++))

	mini_out=$(printf '%s' "$input" | timeout 5 "$MINI" 2>/tmp/ra_mini_err_$$)
	mini_exit=$?
	mini_err=$(cat /tmp/ra_mini_err_$$ | normalize)
	mini_out=$(printf '%s' "$mini_out" | strip_prompt)

	bash_out=$(printf '%s' "$input" | timeout 5 bash --norc --noprofile 2>/tmp/ra_bash_err_$$)
	bash_exit=$?
	bash_err=$(cat /tmp/ra_bash_err_$$ | normalize)

	rm -f /tmp/ra_mini_err_$$ /tmp/ra_bash_err_$$

	vg_out=$(printf '%s' "$input" | timeout 10 $VG "$MINI" 2>/tmp/ra_vg_$$)
	vg_code=$?
	vg_full=$(cat /tmp/ra_vg_$$)
	vg_leak=$(grep -E "definitely lost|indirectly lost|still reachable" /tmp/ra_vg_$$ | grep -v "0 bytes")
	vg_err2=$(grep "ERROR SUMMARY" /tmp/ra_vg_$$ | grep -v "0 errors")
	rm -f /tmp/ra_vg_$$

	local fail=0
	local warn=0
	local leak=0

	[ "$mini_exit" != "$bash_exit" ] && fail=1
	[ "$mini_out"  != "$bash_out"  ] && fail=1
	if [ $fail -eq 0 ] && [ "$mini_err" != "$bash_err" ] && [ -n "$mini_err" ] && [ -z "$bash_err" ]; then
		local _sim
		_sim=$(stderr_sim "$mini_err" "$bash_err")
		[ "$_sim" -lt 50 ] && warn=1
	fi

	if [ $vg_code -eq 99 ] || [ -n "$vg_leak" ] || [ -n "$vg_err2" ]; then
		leak=1
		((TOTAL_LEAK++))
	fi

	local status
	if [ $fail -eq 1 ]; then
		status="FAIL"
		((TOTAL_FAIL++))
	elif [ $warn -eq 1 ]; then
		status="WARN"
		((TOTAL_WARN++))
	else
		status="OK"
		((TOTAL_PASS++))
	fi
	[ $leak -eq 1 ] && status="${status}+LEAK"

	if should_display $fail $warn $leak 0; then
		printf "\n"
		if [ $fail -eq 1 ]; then
			echo -e "${RED}[FAIL]${NC} ${desc}"
		elif [ $warn -eq 1 ]; then
			echo -e "${YELLOW}[WARN]${NC} ${desc}"
		else
			echo -e "${GREEN}[OK  ]${NC} ${desc}"
		fi
		echo -e "  ${CYAN}\$>${NC} $(echo "$input" | head -1)"
		echo -e "  ${GREEN}my minishell${NC} [exit=${mini_exit}]: $(echo "${mini_out}${mini_err}" | head -3 | tr '\n' ' ')"
		if [ $fail -eq 1 ]; then
			echo -e "  ${YELLOW}bash         ${NC} [exit=${bash_exit}]: $(echo "${bash_out}${bash_err}" | head -3 | tr '\n' ' ')"
			[ "$mini_exit" != "$bash_exit" ] && echo -e "  ${RED}!! exit différent${NC}"
			[ "$mini_out"  != "$bash_out"  ] && echo -e "  ${RED}!! stdout différent${NC}"
			[ "$mini_err"  != "$bash_err"  ] && echo -e "  ${RED}!! stderr différent${NC}"
		elif [ $warn -eq 1 ]; then
			echo -e "  ${YELLOW}!! stderr différent${NC}"
		fi
		if [ $leak -eq 1 ]; then
			echo -e "  ${RED}leaks valgrind:${NC}"
			echo "$vg_full" | grep -v "^$" | sed 's/^/    /'
		fi
		log_test "$TEST_NUM" "$desc" "$status" "$input" \
			"$mini_out" "$mini_err" "$mini_exit" \
			"$bash_out" "$bash_err" "$bash_exit" "$vg_full"
	fi
	_progress
}

# Comparaison bash vs mini tous deux sous env -i (sans valgrind — env -i + VG trop fragile)
check_ei() {
	local desc="$1"
	local input="$2"
	[ $SKIP_SECTION -eq 1 ] && return
	((TEST_NUM++))

	if [ -n "$_FAKE_RL" ]; then
		mini_out=$(printf '%s' "$input" | timeout 5 env -i LD_PRELOAD="$_FAKE_RL" "$MINI" 2>/tmp/ra_mini_err_$$)
	else
		mini_out=$(printf '%s' "$input" | timeout 5 env -i "$MINI" 2>/tmp/ra_mini_err_$$)
	fi
	mini_exit=$?
	mini_err=$(cat /tmp/ra_mini_err_$$ | normalize)
	mini_out=$(printf '%s' "$mini_out" | strip_prompt)

	bash_out=$(printf '%s' "$input" | timeout 5 env -i bash --norc --noprofile 2>/tmp/ra_bash_err_$$)
	bash_exit=$?
	bash_err=$(cat /tmp/ra_bash_err_$$ | normalize)

	rm -f /tmp/ra_mini_err_$$ /tmp/ra_bash_err_$$

	local fail=0 warn=0

	[ "$mini_exit" != "$bash_exit" ] && fail=1
	[ "$mini_out"  != "$bash_out"  ] && fail=1
	if [ $fail -eq 0 ] && [ "$mini_err" != "$bash_err" ] && [ -n "$mini_err" ] && [ -z "$bash_err" ]; then
		local _sim
		_sim=$(stderr_sim "$mini_err" "$bash_err")
		[ "$_sim" -lt 50 ] && warn=1
	fi

	local status
	if [ $fail -eq 1 ]; then
		status="FAIL"; ((TOTAL_FAIL++))
	elif [ $warn -eq 1 ]; then
		status="WARN"; ((TOTAL_WARN++))
	else
		status="OK"; ((TOTAL_PASS++))
	fi

	if should_display $fail $warn 0 0; then
		printf "\n"
		if [ $fail -eq 1 ]; then
			echo -e "${RED}[FAIL]${NC} ${desc}"
		elif [ $warn -eq 1 ]; then
			echo -e "${YELLOW}[WARN]${NC} ${desc}"
		else
			echo -e "${GREEN}[OK  ]${NC} ${desc}"
		fi
		echo -e "  ${CYAN}\$>${NC} $(echo "$input" | head -1)"
		echo -e "  ${GREEN}my minishell${NC} [exit=${mini_exit}]: $(echo "${mini_out}${mini_err}" | head -3 | tr '\n' ' ')"
		if [ $fail -eq 1 ]; then
			echo -e "  ${YELLOW}bash         ${NC} [exit=${bash_exit}]: $(echo "${bash_out}${bash_err}" | head -3 | tr '\n' ' ')"
			[ "$mini_exit" != "$bash_exit" ] && echo -e "  ${RED}!! exit différent${NC}"
			[ "$mini_out"  != "$bash_out"  ] && echo -e "  ${RED}!! stdout différent${NC}"
			[ "$mini_err"  != "$bash_err"  ] && echo -e "  ${RED}!! stderr différent${NC}"
		elif [ $warn -eq 1 ]; then
			echo -e "  ${YELLOW}!! stderr différent${NC}"
		fi
		log_test "$TEST_NUM" "$desc" "$status" "$input" \
			"$mini_out" "$mini_err" "$mini_exit" \
			"$bash_out" "$bash_err" "$bash_exit" ""
	fi
	_progress
}

# Crash only + valgrind (pas de comparaison bash)
vcheck() {
	local desc="$1"
	local input="$2"
	local env_prefix="${3:-}"
	[ $SKIP_SECTION -eq 1 ] && return
	((TEST_NUM++))

	_vld=""; [ -n "$_FAKE_RL" ] && _vld="LD_PRELOAD=$_FAKE_RL"
	if [ -n "$env_prefix" ]; then
		mini_out=$(printf '%s' "$input" | timeout 5 env -i $_vld $env_prefix "$MINI" 2>/tmp/ra_mini_err_$$)
	else
		mini_out=$(printf '%s' "$input" | timeout 5 "$MINI" 2>/tmp/ra_mini_err_$$)
	fi
	mini_exit=$?
	mini_out=$(printf '%s' "$mini_out" | strip_prompt)
	rm -f /tmp/ra_mini_err_$$

	if [ $mini_exit -eq 124 ]; then
		((TOTAL_CRASH++))
		if should_display 0 0 0 1; then
			printf "\n"
			echo -e "${RED}[TIMEOUT]${NC} ${desc}"
			echo -e "  ${CYAN}\$>${NC} $(echo "$input" | head -1)"
			log ""; log "Test ${TEST_NUM}: ${desc}  [TIMEOUT]"
			log "\$> $(echo "$input" | head -1)"
		fi
		_progress; return
	fi
	if [ $mini_exit -ge 134 ] && [ $mini_exit -le 139 ]; then
		((TOTAL_CRASH++))
		if should_display 0 0 0 1; then
			printf "\n"
			echo -e "${RED}[CRASH  ]${NC} ${desc} (exit=$mini_exit)"
			echo -e "  ${CYAN}\$>${NC} $(echo "$input" | head -1)"
			log ""; log "Test ${TEST_NUM}: ${desc}  [CRASH exit=${mini_exit}]"
			log "\$> $(echo "$input" | head -1)"
		fi
		_progress; return
	fi

	if [ -n "$env_prefix" ]; then
		vg_out=$(printf '%s' "$input" | timeout 10 env -i $_vld $env_prefix $VG "$MINI" 2>/tmp/ra_vg_$$)
	else
		vg_out=$(printf '%s' "$input" | timeout 10 $VG "$MINI" 2>/tmp/ra_vg_$$)
	fi
	vg_code=$?
	vg_full=$(cat /tmp/ra_vg_$$)
	vg_leak=$(grep -E "definitely lost|indirectly lost|still reachable" /tmp/ra_vg_$$ | grep -v "0 bytes")
	vg_errs=$(grep "ERROR SUMMARY" /tmp/ra_vg_$$ | grep -v "0 errors")
	rm -f /tmp/ra_vg_$$

	if [ $vg_code -eq 99 ] || [ -n "$vg_leak" ] || [ -n "$vg_errs" ]; then
		((TOTAL_LEAK++))
		((TOTAL_PASS++))
		if should_display 0 0 1 0; then
			printf "\n"
			echo -e "${RED}[LEAK  ]${NC} ${desc}"
			echo -e "  ${CYAN}\$>${NC} $(echo "$input" | head -1)"
			echo -e "  ${GREEN}my minishell${NC} [exit=${mini_exit}]: $(echo "${mini_out}" | head -3 | tr '\n' ' ')"
			echo -e "  ${RED}leaks valgrind:${NC}"
			echo "$vg_full" | grep -v "^$" | sed 's/^/    /'
			log ""; log "Test ${TEST_NUM}: ${desc}  [LEAK]"
			log "\$> $(echo "$input" | head -1)"
			log "  --- VALGRIND OUTPUT COMPLET ---"
			while IFS= read -r line; do
				log "    $line"
			done <<< "$vg_full"
			log "  --- FIN VALGRIND ---"
		fi
	else
		((TOTAL_PASS++))
		if should_display 0 0 0 0; then
			printf "\n"
			echo -e "${GREEN}[CLEAN ]${NC} ${desc}"
			echo -e "  ${CYAN}\$>${NC} $(echo "$input" | head -1)"
			echo -e "  ${GREEN}my minishell${NC} [exit=${mini_exit}]: $(echo "${mini_out}" | head -3 | tr '\n' ' ')"
			log ""; log "Test ${TEST_NUM}: ${desc}  [OK]"
			log "\$> $(echo "$input" | head -1)"
		fi
	fi
	_progress
}

section() {
	local num
	num=$(printf '%s' "$1" | grep -oE '^\[[0-9]+\]' | tr -d '[]')
	num=${num:-0}
	if [ "$num" -gt 0 ] && { [ "$num" -lt "$SEC_FROM" ] || [ "$num" -gt "$SEC_TO" ]; }; then
		SKIP_SECTION=1
		return
	fi
	SKIP_SECTION=0
	printf "\n"
	echo -e "\n${BOLD}${CYAN}$1${NC}"
	CURRENT_SECTION="$1"
	log_header "$1"
}

# Supprime les artefacts connus d'un run précédent avant le snapshot
find . -maxdepth 1 -type f ! -name "*.c" ! -name "*.h" ! -name "*.sh" \
	! -name "*.so" ! -name "*.supp" ! -name "*.txt" ! -name "*.md" \
	! -name "Makefile" ! -name "minishell" ! -name ".gitignore" -delete 2>/dev/null

# Snapshot des fichiers présents avant les tests
_BEFORE_FILES=$(ls -1 . 2>/dev/null | sort)

# ─────────────────────────────────────────────
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  MINISHELL — ALL TESTS + VALGRIND${NC}"
if [ "$SEC_FROM" -ne 1 ] || [ "$SEC_TO" -lt 22 ]; then
	if [ "$SEC_FROM" -eq "$SEC_TO" ]; then
		echo -e "${CYAN}  Filtre : catégorie [$SEC_FROM] uniquement  ($TOTAL_TESTS tests)${NC}"
	else
		echo -e "${CYAN}  Filtre : catégories [$SEC_FROM] à [$SEC_TO]  ($TOTAL_TESTS tests)${NC}"
	fi
fi
echo -e "${CYAN}================================================================${NC}"

# ══════════════════════════════════════════════
section "[1] PIPES"
# ══════════════════════════════════════════════
check  "simple pipe"                  "echo hello | cat"
check  "triple pipe"                  "echo a | cat | cat"
check  "pipe chain 6"                 "ls | cat | cat | cat | cat | cat"
check  "pipe invalid cmds"            "ls | ldkdkd | ls | lk"
check  "pipe no left"                 "| ls"
check  "pipe no right"                "ls |"
check  "pipe empty string"            "echo '' | cat"
check  "pipe newline"                 'printf "a\nb\nc" | wc -l'
check  "pipe to grep"                 "echo hello | grep hello"
check  "pipe many invalid"            "lkjh | lkjh | lkjh | lkjh | lkjh"
check  "pipe exit code"               "false | true"
check  "pipe all invalid 10x"         "$(python3 -c "print(' | '.join(['invalid_xyz']*10))")"
vcheck "pipe 20x ls"                  "$(python3 -c "print(' | '.join(['ls']*20))")"
vcheck "pipe 50x ls"                  "$(python3 -c "print(' | '.join(['ls']*50))")"

# ══════════════════════════════════════════════
section "[2] REDIRECTIONS"
# ══════════════════════════════════════════════
vcheck "redirect out"                 "echo hello > /tmp/ra_out.txt"
vcheck "redirect append"              "echo hello >> /tmp/ra_app.txt"
vcheck "redirect in"                  "cat < /tmp/ra_out.txt"
check  "redirect no file >"           "> "
check  "redirect no file <"           "< "
check  "redirect no file >>"          ">> "
check  "redirect no file <<"          "cat <<"
check  "redirect nonexist <"          "cat < /nonexistent_file_xyz"
check  "> dossier"                    "echo hi > /tmp"
check  "< dossier"                    "cat < /tmp"
check  "> sans permission"            "echo hi > /root/noperm_xyz.txt"
check  ">> sans permission"           "echo hi >> /root/noperm_xyz.txt"
vcheck "multiple > same cmd"          "echo hi > /tmp/ra_m1.txt > /tmp/ra_m2.txt"
check  "> /dev/full"                  "echo hi > /dev/full"
vcheck "pipe then redir"              "echo hi | cat > /tmp/ra_pr.txt"

check  "< < < espace séparé"          "cat < < < hello"
check  "> > > espace séparé"          "echo hi > > > /tmp/ra_sp.txt"

# ══════════════════════════════════════════════
section "[3] HEREDOC"
# ══════════════════════════════════════════════
vcheck "heredoc basic"                $'cat <<EOF\nhello world\nEOF'
vcheck "heredoc empty"                $'cat <<EOF\nEOF'
vcheck "heredoc no term"              "cat <<EOF"
vcheck "heredoc with var"             $'cat <<EOF\n$HOME\nEOF'
vcheck "heredoc quoted delim"         $'cat <<"EOF"\n$HOME\nEOF'
vcheck "heredoc pipe after"           $'cat <<EOF | cat\nhello\nEOF'

# ══════════════════════════════════════════════
section "[4] QUOTES"
# ══════════════════════════════════════════════
check  "double quotes basic"          'echo "hello world"'
check  "single quotes basic"          "echo 'hello world'"
check  "mixed quotes"                 "echo \"hello\" 'world'"
check  "unclosed double"              'echo "hello'
check  "unclosed single"              "echo 'hello"
check  "empty double quotes"          'echo ""'
check  "empty single quotes"          "echo ''"
check  "quote avec dollar"            'echo "$HOME"'
check  "single no expand"             "echo '\$HOME'"
check  "nested single in double"      'echo "hel'"'"'lo"'
check  "double in single"             "echo 'hel\"lo'"
check  "quote with pipe"              'echo "a|b"'
check  "quote with redirect"          'echo "a>b"'
check  "alternating quotes"           "echo 'a'\"b\"'c'\"d\""

# ══════════════════════════════════════════════
section "[5] VARIABLES / EXPANSION"
# ══════════════════════════════════════════════
check  "expand HOME"                  "echo \$HOME"
check  "expand PATH"                  "echo \$PATH"
check  "expand var inexistante"       "echo \$NONEXISTENT_VAR_XYZ"
check  "expand ?"                     "echo \$?"
check  "expand in quotes"             'echo "$HOME"'
check  "single no expand"             "echo '\$HOME'"
check  "dollar alone"                 "echo \$"
check  "dollar digit"                 "echo \$1"
vcheck "very long expansion"          "echo \$HOME\$HOME\$HOME\$HOME\$HOME\$HOME\$HOME\$HOME"

# ══════════════════════════════════════════════
section "[6] BUILTINS — echo"
# ══════════════════════════════════════════════
check  "echo basic"                   "echo hello"
check  "echo -n"                      "echo -n hello"
check  "echo -n -n"                   "echo -n -n"
check  "echo multiple args"           "echo a b c d e"
check  "echo empty"                   "echo"
check  "echo empty quotes"            "echo '' \"\""

# ══════════════════════════════════════════════
section "[7] BUILTINS — cd"
# ══════════════════════════════════════════════
check  "cd no arg"                    "cd"
check  "cd /"                         "cd /"
check  "cd nonexist"                  "cd /nonexistent_xyz_abc"
check  "cd dotdot"                    "cd .."
check  "cd dot"                       "cd ."
check  "cd trop d'args"               "cd /tmp /var"
check  "cd empty string"              "cd ''"
check  "cd sans HOME"                 "unset HOME"
vcheck "cd /tmp clean"                "cd /tmp"
vcheck "cd nonexist leak"             "cd /nonexistent_xyz"

# ══════════════════════════════════════════════
section "[8] BUILTINS — export"
# ══════════════════════════════════════════════
vcheck "export simple"                "export _VG_A=hello"
vcheck "export empty val"             "export _VG_A="
vcheck "export no val"                "export _VG_A"
check  "export invalid chiffre"       "export 1BAD=val"
check  "export invalid ="             "export =badval"
check  "export invalid tiret"         "export bad-name=val"
check  "export invalid @"             "export bad@name=val"
vcheck "export quoted val"            "export _VG_A=\"hello world\""
vcheck "export single quotes val"     "export _VG_A='hello'"
vcheck "export empty dbl"             "export _VG_A=\"\""
vcheck "export empty sgl"             "export _VG_A=''"

# Export + quotes (bug connu — échoue jusqu'à fix)
check  "export dbl wraps singles vides"  $'export _A="\'\'"\necho $_A'
check  "export dbl wraps single mot"     $'export _A="\'hello\'"\necho $_A'
check  "export dbl singles vides+\$USER" $'export _A="\'\'$USER\'\'"\necho $_A'
check  "export dbl \$USER entre singles" $'export _A="\'$USER\'"\necho $_A'
check  "export sgl contient dbl quotes"  $'export _A='"'"'""'"'"'\necho $_A'
check  "export sgl wraps dbl mot"        $'export _A='"'"'"hello"'"'"'\necho $_A'
check  "export alternance sgl dbl"       $'export _A='"'"'a'"'"'"b"'"'"'c'"'"'\necho $_A'
check  "export alternance dbl sgl"       $'export _A="a"'"'"'b'"'"'"c"\necho $_A'
check  "export singles+var milieu"       $'export _A="\'\'$USER"\necho $_A'
check  "export var+singles fin"          $'export _A="$USER\'\'"\necho $_A'
check  "export 4 singles vides"          $'export _A="\'\'\'\'"\necho $_A'
check  "export singles intercalés"       $'export _A="a\'b\'c\'d"\necho $_A'
check  "export overwrite avec quotes"    $'export _A="\'old\'"\nexport _A="\'new\'"\necho $_A'
check  "export puis unset"              $'export _A="\'val\'"\nunset _A\necho $_A'

# ── export VAR (sans valeur) vs export VAR= (valeur vide) ──
# export TOM   → marqué export, PAS dans env (pas de valeur)
# export TOM=  → dans env avec valeur vide, dans export avec ""
check "export VAR sans =: hors env"        $'export _RA_TOM\nenv | grep -c "^_RA_TOM"'
check "export VAR sans =: dans export"     $'export _RA_TOM\nexport | grep -c "_RA_TOM"'
check "export VAR sans =: echo empty"      $'export _RA_TOM\necho "[$_RA_TOM]"'
check "export VAR= vide: dans env"         $'export _RA_TOM=\nenv | grep "^_RA_TOM"'
check "export VAR= vide: dans export"      $'export _RA_TOM=\nexport | grep -c "_RA_TOM"'
check "export VAR= vide: echo empty str"   $'export _RA_TOM=\necho "[$_RA_TOM]"'
check "export VAR puis VAR=set: env ok"    $'export _RA_TOM\nexport _RA_TOM=hello\nenv | grep "^_RA_TOM"'
check "env: sans= absent, avec= présent"   $'export _RA_A\nexport _RA_B=\nenv | grep -c "^_RA_A"\nenv | grep -c "^_RA_B"'

# ── Ordre alphabétique de export ──
# On exporte en ordre inverse, export doit ressortir trié
check "export alphabetique: A avant Z"  $'export _RA_ZZZ=z\nexport _RA_AAA=a\nexport _RA_MMM=m\nexport | grep "_RA_" | sed "s/declare -x //" | cut -d= -f1'
check "export alphabetique: chiffres"   $'export _RA_Z9=z\nexport _RA_A1=a\nexport _RA_M5=m\nexport | grep "_RA_" | sed "s/declare -x //" | cut -d= -f1'

# ══════════════════════════════════════════════
section "[9] BUILTINS — unset"
# ══════════════════════════════════════════════
check  "unset no args"                "unset"
check  "unset nonexist"               "unset NONEXIST_VAR_ZZZ"
check  "unset invalid chiffre"        "unset 1BAD"
check  "unset invalid tiret"          "unset bad-name"
vcheck "unset HOME"                   "unset HOME"
vcheck "unset existing"               "unset PATH"

# ══════════════════════════════════════════════
section "[10] BUILTINS — exit"
# ══════════════════════════════════════════════
check  "exit arg non numérique"       "exit abc"
check  "exit arg alphanum"            "exit 1abc"
check  "exit trop d'args"             "exit 1 2 3"
vcheck "exit 0"                       "exit 0"
vcheck "exit 1"                       "exit 1"
vcheck "exit 42"                      "exit 42"
vcheck "exit 126"                     "exit 126"
vcheck "exit 127"                     "exit 127"
vcheck "exit sans arg"                "exit"

# ══════════════════════════════════════════════
section "[11] BUILTINS — env / pwd"
# ══════════════════════════════════════════════
vcheck "env"                          "env"
vcheck "pwd"                          "pwd"
check  "pwd with args"                "pwd /tmp"

# ══════════════════════════════════════════════
section "[12] COMMANDES INTROUVABLES / PERMISSIONS"
# ══════════════════════════════════════════════
check  "cmd inexistant"               "thiscmddoesnotexist"
check  "./relatif inexistant"         "./nonexistent_xyz"
check  "chemin absolu inexistant"     "/nonexistent_xyz"
touch /tmp/ra_noperm.sh && chmod 000 /tmp/ra_noperm.sh
check  "exec sans permission (exit 126)" "/tmp/ra_noperm.sh"
chmod 644 /tmp/ra_noperm.sh
check  "exec non exécutable 644"      "/tmp/ra_noperm.sh"
rm -f /tmp/ra_noperm.sh

# ══════════════════════════════════════════════
section "[13] SANS PATH / ENV VIDE"
# ══════════════════════════════════════════════
vcheck "echo sans PATH"               "echo hello"                     "HOME=/tmp"
vcheck "cmd not found sans PATH"      "ls"                             "HOME=/tmp"
vcheck "pipe absolu sans PATH"        "/bin/echo hi | /bin/cat"        "HOME=/tmp"
vcheck "pipe cmd not found sans PATH" "ls | cat"                       "HOME=/tmp"
vcheck "export sans PATH"             "export _VG_B=hello"             "HOME=/tmp"
vcheck "env vide echo"                "echo hello"                     ""
vcheck "env vide cmd not found"       "ls"                             ""
vcheck "env vide pipe absolu"         "/bin/echo hi | /bin/cat"        ""
vcheck "env vide redir"               "/bin/echo hi > /tmp/ra_ev.txt"  ""
vcheck "env vide heredoc"             $'/bin/cat <<EOF\nhello\nEOF'    ""
vcheck "env vide exit"                "exit 0"                         ""

# ══════════════════════════════════════════════
section "[14] EDGE CASES"
# ══════════════════════════════════════════════
vcheck "empty input"                  ""
vcheck "only spaces"                  "   "
vcheck "tilde"                        "echo ~"
vcheck "slash cmd"                    "/bin/echo hello"
vcheck "very long cmd"                "echo $(python3 -c "print('a'*5000)")"
vcheck "many args"                    "$(python3 -c "print('echo ' + ' '.join(['arg']*300))")"
vcheck "null cmd quotes"              "\"\""
vcheck "dollar question pipe"         "false | echo \$?"

# ══════════════════════════════════════════════
section "[15] TESTS REPOS ETUDIANTS — CRASH / SEGFAULT"
# ══════════════════════════════════════════════

# ── Segfault bait (mini_death / parsing_hell) ──
check  "echo <| echo"                 "echo |< echo segf"
check  "echo > > < echo"             'echo > > < "echo"'
check  "echo > > | echo"             "echo > > | echo kekw"
check  "echo < < > echo"             "echo < < > echo"
check  "echo < < < > ok"             "echo < < < > ok"
check  "echo < < | echo"             "echo < < | echo ok"
check  "echo < < | < ok"             "echo < < | < ok"
check  "echo < < | > echo"           "echo < < | > echo"
check  "echo >>< echo"               'echo >>< "echo"'
check  "echo <<| echo"               "echo <<| echo ok"
check  "echo <<|< ok"                "echo <<|< ok"
check  "echo <<|> echo"              "echo <<|> echo"
check  "echo <<> echo"               "echo <<> echo"
check  "echo seg < > echo"           "echo seg < > echo seg"
check  "echo seg > < echo"           "echo seg > < echo segf"
check  "echo seg < < > echo"         "echo seg < < > echo segf"
check  "echo | > la"                 "echo | > la"
check  "<| echo ok"                  "<| echo ok"
check  "<| echo wtf"                 "<| echo wtf"
check  "<<| echo wtf"                "<<| echo wtf"

# ── Quotes folles sur le nom de commande ──
vcheck "commande tout-quotes"         'p""'"'''"'w'"''''''""""""'"''"''"''"''"''"''"''"''"''"''"''"''"''"''"''"''"''"''"''"'d"
vcheck "echo vide + ok"              "''echo ok"
vcheck "echo dbl vide + ok"          '""echo ok'
vcheck "cmd entre doubles"           '"echo" 42'
vcheck "cmd entre singles"           "'echo' 42"
vcheck "ls entre singles/doubles"    "''''''\"ls\"''''''"
vcheck "echo flag quote"             'echo -n"-n" bonjour'

# ── Exit cas extrêmes ──
check  "exit très grand positif"      "exit 9223372036854775807"
check  "exit overflow positif"        "exit 9223372036854775808"
check  "exit très grand négatif"      "exit -9223372036854775808"
check  "exit overflow négatif"        "exit -9223372036854775809"
check  "exit infini positif"          "exit 9999999999999999999999999999999999"
check  "exit infini négatif"          "exit -9999999999999999999999999999999999"
check  "exit +42"                     "exit +42"
check  "exit -42"                     "exit -42"
check  "exit +0"                      "exit +0"
check  "exit -0"                      "exit -0"
check  "exit 00000...1"               "exit 00000000000000000000000000000000001"
check  "exit 00000...0"               "exit 00000000000000000000000000000000000"
check  "exit 42 abc"                  "exit 42 abc"
check  "exit abc 42"                  "exit abc 42"
check  "exit 123\"123\""             'exit 123"123"'
check  "exit ' 5'"                    "exit ' 5'"
check  "exit '5 '"                    "exit '5 '"
check  "exit '5  x'"                  "exit '5     x'"
check  "exit _0"                      "exit _0"
check  "exit 0_"                      "exit 0_"
check  "exit +"                       "exit +"
check  "exit -"                       "exit -"
check  "exit ++"                      "exit ++"
check  "exit --"                      "exit --"
check  "exit +++"                     "exit +++"
check  "exit ---"                     "exit ---"
check  "exit 5 < infile"              "exit 5 < /dev/null"

# ── Export cas extrêmes ──
check  "export A==a"                  $'export A==a\necho $A'
check  "export A===a"                 $'export A===a\necho $A'
check  "export A=a=a=a"              $'export A=a=a=a=a=a\necho $A'
check  "export long chain"            "export A=a B=b C=c D=d E=e F=f G=g H=h I=i J=j"
check  "export T=>> puis \$T"         $'export T=">>"\n$T lol'
check  "export T=| puis \$T"          $'export T="|"\necho segfault $T grep segfault'
check  "export T=< puis \$T"          $'export T="<"\necho segfault $T grep segfault'
check  "export T=<< puis \$T"         $'export T="<<"\necho segfault $T grep segfault'
check  "export T=| \$T\$T\$T"         $'export T="|"\n$T$T$T$T$T$T$T'
check  "export \$?"                   "export \$?"
check  "export ?=val"                 "export ?=val"
check  "export ''=''"                 "export ''=''"
check  "export \"\"=\"\""             'export ""=""'
check  "export ="                     "export ="
check  "export =============="        "export =============="
check  "export +++++++=123"           "export +++++++=123"

# ── Cd cas extrêmes ──
check  "cd --"                        "cd --"
check  "cd +"                         "cd +"
check  "cd ?"                         "cd ?"
check  "cd //////"                    "cd //////"
check  "cd ./././"                    "cd ./././"
check  "cd trop profond"              "cd ../../../../../../../../../../../../../../.."
check  "cd arg invalide"              "cd bark bark"

# ── Variables extrêmes ──
check  "echo \$U/SER"                 "echo \$U/SER"
check  "echo \$/ \$/"                 "echo \$/ \$/"
check  "\$? seul"                     "\$?"
check  "echo \$USER42"               "echo \$USER42"
check  "echo \$USER\$"               "echo \$USER\$"
check  "echo hello\$NOT \$USER"      "echo hello \$NOT_A_VAR \$NOT_A_VAR \$USER"

# ── Echo cas extrêmes ──
check  "echo -nnnnnnnnnn"             "echo -nnnnnnnnnn"
check  "echo -n -nnn -nnnnn"          "echo -n -nnn -nnnnn feel my pain"
check  "echo -n -n -n-n"             "echo -n -n -n-n"
check  "echo -"                       "echo -"
check  "echo --"                      "echo --"
check  "ECHO majuscule"               "ECHO hello"
check  "Echo mixte"                   "Echo hello"
check  "ec\"\"ho"                     'ec""ho test'
check  "ec''ho"                       "ec''ho test"
check  "\"\"echo"                     '""echo test'
check  "''echo"                       "''echo test"
check  "echo\"\" test"                'echo"" test'
check  "echo '' \"\" ''"             "echo '' \"\" '' test"
check  "echo a '' b '' c"            "echo a '' b '' c"

# ── Pipes extrêmes du repo ──
check  "echo | echo | echo | grep"   "echo 42 | echo no | echo smth | grep 42"
check  "pipe sleep 0 10x"             "sleep 0 | cat | cat | cat | cat | cat | cat | cat | cat | cat | cat | cat"
check  "pipe cmd invalide milieu"     "cat infile_none | x | grep dream | wc -l"
check  "pipe exit dans pipe"         "exit 1 | exit 0"
check  "exit | ls"                    "exit | ls"
check  "ls | exit"                    "ls | exit"
check  "ls | exit 42"                 "ls | exit 42"
check  "cat | cat | ls"              "cat | cat | ls"

# ── Heredoc extrêmes ──
vcheck "heredoc delim var"            $'cat << $USER\nwhy\nnot\n$USER'
vcheck "heredoc delim quotes mix"     $'cat << "$US"E"R"\nbecause\nwe\nlove\nbash\n$USER'
vcheck "heredoc pipe gauche"          $'ls | cat << stop | grep "asd"\nstop'
check  "heredoc + redirect combo"     $'cat << here -e\nhello\nhere'
check  "<< echo oi"                   "<< echo oi"

# ── Syntax errors repo ──
check  "| seul"                       "|"
check  "pipe vide | |"                "ls | | cat"
check  "pipe faux gauche"             "| fake_cmd"
check  "pipe faux droite"             "fake_cmd |"
check  "ls | < pipe"                  "ls | <"
check  "ls | << pipe"                 "ls | <<"
check  "ls | > pipe"                  "ls | >"
check  "ls | >> pipe"                 "ls | >>"
check  "ls > > "                      "ls > >"
check  "ls > >> "                     "ls > >>"
check  "ls > < "                      "ls > <"
check  "ls >> > "                     "ls >> >"
check  "ls << < "                     "ls << <"
check  "echo hello | ;"              "echo hello | ;"
check  "> > > > >"                   "> > > > >"
check  ">> >> >> >>"                  ">> >> >> >>"
check  "< < < < < <"                  "< < < < < <"
check  "EechoE"                       "EechoE"
check  ".echo."                       ".echo."
check  ">echo>"                       ">echo>"
check  "<echo<"                       "<echo<"
check  "|echo|"                       "|echo|"
check  "| test"                       "| test"
check  "| | | | test"                "| | | | test"
check  "<>"                           "<>"
check  "< >"                          "< >"
check  "unset \$HOME"                 "unset \$HOME"

# ══════════════════════════════════════════════
section "[16] FILESYSTEM — DOSSIER/FICHIER SUPPRIMÉ SOUS LES PIEDS"
# ══════════════════════════════════════════════

# Nettoyage préalable des dirs de test
rm -rf /tmp/ms_fs_a /tmp/ms_fs_b /tmp/ms_fs_c /tmp/ms_fs_d /tmp/ms_fs_e \
       /tmp/ms_fs_f /tmp/ms_fs_g /tmp/ms_fs_h /tmp/ms_fs_vg1 /tmp/ms_fs_vg2 \
       /tmp/ms_fs_vg3 /tmp/ms_fs_vg4 /tmp/ms_fs_vg5

# ── cd dans un dossier puis le supprimer ──
check  "mkdir+cd+rm+pwd"              $'mkdir /tmp/ms_fs_a\ncd /tmp/ms_fs_a\nrm -rf /tmp/ms_fs_a\npwd'
check  "mkdir+cd+rm+ls"               $'mkdir /tmp/ms_fs_b\ncd /tmp/ms_fs_b\nrm -rf /tmp/ms_fs_b\nls'
check  "mkdir+cd+rm+cd .."            $'mkdir /tmp/ms_fs_c\ncd /tmp/ms_fs_c\nrm -rf /tmp/ms_fs_c\ncd ..'
check  "mkdir+cd+rm+echo ok"          $'mkdir /tmp/ms_fs_d\ncd /tmp/ms_fs_d\nrm -rf /tmp/ms_fs_d\necho ok'
check  "mkdir+cd+rm+echo \$PWD"       $'mkdir /tmp/ms_fs_e\ncd /tmp/ms_fs_e\nrm -rf /tmp/ms_fs_e\necho $PWD'
check  "mkdir+cd+rm+export+echo"      $'mkdir /tmp/ms_fs_f\ncd /tmp/ms_fs_f\nrm -rf /tmp/ms_fs_f\nexport X=hello\necho $X'

# ── Nesting : mkdir a/b, cd a/b, rm -rf a ──
check  "mkdir a/b+cd b+rm a+pwd"      $'mkdir -p /tmp/ms_fs_g/b\ncd /tmp/ms_fs_g/b\nrm -rf /tmp/ms_fs_g\npwd'
check  "mkdir a/b+cd b+rm a+ls"       $'mkdir -p /tmp/ms_fs_h/b\ncd /tmp/ms_fs_h/b\nrm -rf /tmp/ms_fs_h\nls'
check  "mkdir a/b/c+cd c+rm a+cd .."  $'mkdir -p /tmp/ms_fs_a/b/c\ncd /tmp/ms_fs_a/b/c\nrm -rf /tmp/ms_fs_a\ncd ..'
check  "mkdir a/b/c+cd c+rm a+pwd"    $'mkdir -p /tmp/ms_fs_b/b/c\ncd /tmp/ms_fs_b/b/c\nrm -rf /tmp/ms_fs_b\npwd'

# ── Fichier créé puis supprimé ──
check  "créer fichier+rm+cat"         $'echo hello > /tmp/ms_fs_file1\nrm /tmp/ms_fs_file1\ncat /tmp/ms_fs_file1'
check  "créer+cat+rm+cat"             $'echo world > /tmp/ms_fs_file2\ncat /tmp/ms_fs_file2\nrm /tmp/ms_fs_file2\ncat /tmp/ms_fs_file2'
check  "redir vers fichier+rm+redir"  $'echo a > /tmp/ms_fs_file3\nrm /tmp/ms_fs_file3\necho b > /tmp/ms_fs_file3\ncat /tmp/ms_fs_file3'
check  "heredoc+rm+cat"               $'cat <<EOF > /tmp/ms_fs_file4\nhello\nEOF\nrm /tmp/ms_fs_file4\ncat /tmp/ms_fs_file4'

# ── pipe dans un dossier supprimé ──
check  "cd+rm+pipe echo|cat"          $'mkdir /tmp/ms_fs_c\ncd /tmp/ms_fs_c\nrm -rf /tmp/ms_fs_c\necho hi | cat'
check  "cd+rm+redir vers fichier"     $'mkdir /tmp/ms_fs_d\ncd /tmp/ms_fs_d\nrm -rf /tmp/ms_fs_d\necho hi > outfile'
check  "cd+rm+pipe+redir"             $'mkdir /tmp/ms_fs_e\ncd /tmp/ms_fs_e\nrm -rf /tmp/ms_fs_e\necho hi | cat > outfile2'

# ── cd dans dir supprimé puis cd ailleurs ──
check  "cd+rm+cd /tmp"                $'mkdir /tmp/ms_fs_f\ncd /tmp/ms_fs_f\nrm -rf /tmp/ms_fs_f\ncd /tmp\npwd'
check  "cd+rm+cd HOME"                $'mkdir /tmp/ms_fs_g\ncd /tmp/ms_fs_g\nrm -rf /tmp/ms_fs_g\ncd\npwd'

# ── Leak valgrind — dossier supprimé ──
vcheck "vg: mkdir+cd+rm+pwd"         $'mkdir /tmp/ms_fs_vg1\ncd /tmp/ms_fs_vg1\nrm -rf /tmp/ms_fs_vg1\npwd'
vcheck "vg: mkdir a/b+cd b+rm a"     $'mkdir -p /tmp/ms_fs_vg2/b\ncd /tmp/ms_fs_vg2/b\nrm -rf /tmp/ms_fs_vg2\npwd'
vcheck "vg: cd+rm+echo ok"           $'mkdir /tmp/ms_fs_vg3\ncd /tmp/ms_fs_vg3\nrm -rf /tmp/ms_fs_vg3\necho ok'
vcheck "vg: cd+rm+pipe"              $'mkdir /tmp/ms_fs_vg4\ncd /tmp/ms_fs_vg4\nrm -rf /tmp/ms_fs_vg4\necho hi | cat'
vcheck "vg: fichier+rm+cat"          $'echo hi > /tmp/ms_fs_vg5\nrm /tmp/ms_fs_vg5\ncat /tmp/ms_fs_vg5'

# Nettoyage post-section
rm -rf /tmp/ms_fs_a /tmp/ms_fs_b /tmp/ms_fs_c /tmp/ms_fs_d /tmp/ms_fs_e \
       /tmp/ms_fs_f /tmp/ms_fs_g /tmp/ms_fs_h /tmp/ms_fs_file1 /tmp/ms_fs_file2 \
       /tmp/ms_fs_file3 /tmp/ms_fs_file4

# ══════════════════════════════════════════════
section "[17] SIGNAUX — SIGINT (^C)"
# ══════════════════════════════════════════════

# Lance mini avec stdin maintenu ouvert via sleep, envoie SIGINT, vérifie pas de crash
sigtest() {
	local desc="$1"
	local pre_input="$2"
	local delay="${3:-0.4}"
	[ $SKIP_SECTION -eq 1 ] && return
	((TEST_NUM++))

	{ printf '%s\n' "$pre_input"; sleep 5; } | timeout 4 "$MINI" >/tmp/ra_sg_$$ 2>&1 &
	local job_pid=$!
	sleep "$delay"
	local grp
	grp=$(ps -o pgid= -p $job_pid 2>/dev/null | tr -d ' ')
	if [ -n "$grp" ] && [ "$grp" != "0" ]; then
		kill -s INT -- -"$grp" 2>/dev/null
	fi
	kill -s INT $job_pid 2>/dev/null
	sleep 0.3
	kill $job_pid 2>/dev/null
	wait $job_pid 2>/dev/null
	local exit_code=$?
	rm -f /tmp/ra_sg_$$

	local crash=0
	[ $exit_code -ge 134 ] && [ $exit_code -le 139 ] && crash=1

	if [ $crash -eq 1 ]; then
		((TOTAL_CRASH++))
		if should_display 0 0 0 1; then
			echo -e "${RED}[CRASH  ]${NC} ^C → ${desc} (exit=$exit_code)"
			echo -e "  ${CYAN}\$>${NC} $(echo "$pre_input" | head -1)  [^C après ${delay}s]"
		fi
		log ""; log "Test ${TEST_NUM}: ^C → ${desc}  [CRASH exit=${exit_code}]"
	else
		((TOTAL_PASS++))
		if should_display 0 0 0 0; then
			echo -e "${GREEN}[OK  ]${NC} ^C → ${desc} (exit=$exit_code)"
			echo -e "  ${CYAN}\$>${NC} $(echo "$pre_input" | head -1)"
		fi
		log ""; log "Test ${TEST_NUM}: ^C → ${desc}  [OK exit=${exit_code}]"
	fi
}

# ── SIGINT pendant commandes bloquantes ──
sigtest "cat bloquant"                "cat"
sigtest "cat|invalid|echo lol (^C)"  "cat | fsfewegweg | echo lol"
sigtest "cat|cat|cat|cat (^C)"       "cat | cat | cat | cat"
sigtest "cat > file bloquant (^C)"   "cat > /tmp/ra_sigcat.txt"
sigtest "cat pipe long 8x (^C)"      "cat | cat | cat | cat | cat | cat | cat | cat"
sigtest "sleep 5 (^C)"               "sleep 5"
sigtest "heredoc sans terminateur"   "cat <<EOF"
sigtest "heredoc ligne ouverte"      $'cat <<EOF\nhello'
sigtest "cmd OK puis ^C rapide"      "echo ok"                          0.1

# ── $? après pipes avec commandes invalides (sans ^C — EOF immédiat) ──
check  "cat EOF|invalid|echo lol"    "echo '' | fsfewegweg | echo lol"
check  "cat|invalid|echo; echo \$?"  $'echo "" | fsfewegweg | echo lol\necho $?'
check  "false|true; echo \$?"        $'false | true\necho $?'
check  "true|false; echo \$?"        $'true | false\necho $?'
check  "invalid|echo ok|invalid"     "invalid_xyz | echo ok | invalid_xyz2"
check  "exit gauche pipe; echo \$?"  $'exit 42 | echo lol\necho $?'
check  "triple false pipe; echo \$?" $'false | false | false\necho $?'

# ══════════════════════════════════════════════
section "[18] TESTS DES MALADES"
# ══════════════════════════════════════════════

# ── Pipe chains extrêmes ──
vcheck "pipe 100x echo|cat"          "$(python3 -c "print(' | '.join(['echo hi']+['cat']*99))")"
check  "pipe 100x invalid"           "$(python3 -c "print(' | '.join(['invalid_xyz']*100))")"
check  "pipe mix valid/invalid 30x"  "$(python3 -c "cmds=['ls' if i%3==0 else 'invalid_xyz' for i in range(30)]; print(' | '.join(cmds))")"
vcheck "yes|head -1"                 "yes | head -n 1"
vcheck "yes|head -100"              "yes | head -n 100"
vcheck "yes|head -10000"            "yes | head -n 10000"

# ── Parsing hell — tokens ambigus ──
check  "echoecho (sans espace)"      "echoecho"
check  "\"echo\" hello"              '"echo" hello'
check  "echo\"echo\"echo lol"        'echo"echo"echo lol'
check  "cat<<EOF sans espace"        "cat<<EOF"
check  ">|<"                         ">|<"
check  "<|>"                         "<|>"
check  ">>|<<"                       ">>|<<"
check  "| | | | | |"                "| | | | | |"
check  "> > > > > >"                "> > > > > >"
check  "<< << << <<"                "<< << << <<"
check  "echo\$HOME sans espace"      'echo$HOME'
check  "\"\"\"\" quadruple dbl"      '"""" hello'
check  "'''''' sextuple sgl"         "''''''"
check  "echo\"\" \"\" \"\""         'echo"" "" ""'
check  "=valeur seul"                "=hello"
check  "==valeur seul"               "==hello"
check  "cmd = arg"                   "echo = hello"
check  "\"\" | cat"                  '"" | cat'
check  "\"\" | \"\" | \"\""          '"" | "" | ""'

# ── Heredoc massacre ──
vcheck "heredoc 500 lignes"          "$(python3 -c "lines=['cat <<EOF'] + ['line'+str(i) for i in range(500)] + ['EOF']; print('\n'.join(lines))")"
check  "heredoc + pipe + grep+redir" $'cat <<EOF | grep hello > /tmp/ra_hpipe.txt\nhello world\nnot this\nEOF\ncat /tmp/ra_hpipe.txt\nrm -f /tmp/ra_hpipe.txt'
check  "heredoc puis syntaxe err"    $'cat <<EOF\nhello\nEOF\nls |'
vcheck "heredoc multi même delim"    $'cat <<X\nhello\nX\ncat <<X\nworld\nX'
check  "heredoc pipeline multiple"   $'cat <<A | cat <<B\nfirst\nA\nsecond\nB'
vcheck "heredoc delim single quote"  $'cat <<\'EOF\'\n$HOME\nEOF'
vcheck "heredoc puis echo \$?"       $'cat <<EOF\nhello\nEOF\necho $?'
check  "heredoc délimiteur vide"     $'cat << \nEOF'
check  "heredoc newline seul delim"  $'cat <<\nEOF'

# ── Variables de destruction ──
check  "unset PATH + ls"             $'unset PATH\nls\necho $?'
check  "unset PATH + /bin/ls"        $'unset PATH\n/bin/ls /tmp\necho $?'
check  "export PATH=/nope + ls"      $'export PATH=/nonexistent_dir_xyz\nls\necho $?'
check  "export HOME=/ + cd + pwd"    $'export HOME=/\ncd\npwd'
check  "export HOME= + cd"           $'export HOME=\ncd\necho $?'
check  "unset HOME + cd"             $'unset HOME\ncd\necho $?'
check  "unset IFS"                   "unset IFS"
check  "export IFS=:"                "export IFS=:"
check  "unset OLDPWD + cd -"         $'unset OLDPWD\ncd -'

# ── Expansion extrême ──
check  "echo \$HOME x10 concat"      'echo $HOME$HOME$HOME$HOME$HOME$HOME$HOME$HOME$HOME$HOME'
check  "\$? après syntax error"      $'ls |\necho $?'
check  "expand dans nom redir"       'echo hi > /tmp/ra_$$_exp.txt 2>/dev/null; rm -f /tmp/ra_$$_exp.txt; echo ok'
check  "double dollar \$\$"          "echo \$\$"
check  "\$? dans variable export"    $'false\nexport X=$?\necho $X'

check  "echo \\n littéral"          'echo \n'
check  "echo \\t littéral"          'echo \t'
check  "echo -e flag"               "echo -e 'hello\nworld'"
check  "echo -E flag"               "echo -E hello"
check  "printf (externe)"           'printf "%s\n" hello world'
check  "& background"               "echo hi &"
check  "; enchaînement"             "echo a; echo b; echo c"

# ── Redirections folles ──
vcheck "50 fichiers diff >>"         "$(python3 -c "files=' '.join(['>> /tmp/ra_mf{}.txt'.format(i) for i in range(50)]); print('echo hi ' + files)")"
check  "cat < < < /dev/null x3"     "cat < /dev/null < /dev/null < /dev/null"
check  "redir vers /dev/stderr"     "echo err > /dev/stderr"
check  "cat /dev/zero|head -c 10"   "cat /dev/zero | head -c 10"
check  "cat /dev/null"              "cat /dev/null"
check  "echo|cat > f|cat < f"       $'echo hello | cat > /tmp/ra_pipe_redir.txt\ncat < /tmp/ra_pipe_redir.txt\nrm -f /tmp/ra_pipe_redir.txt'

# ── Export en masse ──
check  "export 50 vars"             "$(python3 -c "print('\n'.join(['export V{}=val{}'.format(i,i) for i in range(50)]))")"
check  "unset 20 vars"              "$(python3 -c "lines=['export V{}=x'.format(i) for i in range(20)] + ['unset ' + ' '.join(['V{}'.format(i) for i in range(20)])]; print('\n'.join(lines))")"
vcheck "export val 5000 chars"       "export BIGV=$(python3 -c "print('A'*5000)")"
vcheck "export val 50000 chars"      "export BIGV=$(python3 -c "print('A'*50000)")"

# ── Comportements exit/pipe subtils ──
check  "exit | echo (exit côté gauche)"  "exit 0 | echo lol"
check  "echo | exit (exit côté droit)"   "echo lol | exit 42"
check  "pipe 3: exit au milieu"          "echo a | exit 1 | echo b"
check  "exit après cmd invalid"          $'invalid_xyz\necho $?'
check  "exit code pipeline final"        $'true | true | false\necho $?'
check  "exit | ls; echo \$?"             $'exit | ls\necho $?'
check  "ls | exit 42; echo \$?"          $'ls | exit 42\necho $?'
check  "exit 12 | exit 13"              "exit 12 | exit 13"
check  "exit 11 | exit 1 | exit 111"   "exit 11 | exit 1 | exit 111"
check  "exit 0 | exit 42"              "exit 0 | exit 42"
check  "exit 255 | exit 0"             "exit 255 | exit 0"
check  "exit 1|2|3|4"                  "exit 1 | exit 2 | exit 3 | exit 4"
check  "exit pipe: code dernier"       $'exit 12 | exit 13\necho $?'
check  "exit pipe: rien sur stdout"    "exit 5 | exit 7"

# ── Noms de fichiers spéciaux ──
check  "fichier avec espace"        "echo hi > '/tmp/ra file spaces.txt'; cat '/tmp/ra file spaces.txt'; rm '/tmp/ra file spaces.txt'"
check  "fichier commence par -"     "echo hi > /tmp/ra_-dash.txt; cat /tmp/ra_-dash.txt; rm /tmp/ra_-dash.txt"

# ── FD / descripteurs ──
vcheck "ls /proc/self/fd"           "ls /proc/self/fd 2>/dev/null | wc -l"

# Nettoyage post sections 17 et 18
rm -f /tmp/ra_sigcat.txt /tmp/ra_hpipe.txt /tmp/ra_pipe_redir.txt
i=0; while [ $i -lt 50 ]; do rm -f "/tmp/ra_mf${i}.txt"; i=$((i+1)); done

# ══════════════════════════════════════════════
section "[19] HEREDOC — TESTS EXTRÊMES"
# ══════════════════════════════════════════════

# ── Délimiteurs inhabituels ──
vcheck "heredoc delim numérique"         $'cat <<42\nhello\n42'
vcheck "heredoc delim très long (58c)"   "$(python3 -c "d='STOP'+'X'*54; print('cat <<'+d+'\nhello\n'+d)")"
vcheck "heredoc delim avec underscore"   $'cat <<MY_DELIM_123\nhello\nMY_DELIM_123'
vcheck "heredoc delim majuscules mix"    $'cat <<HEREend\nhello\nHEREend'
check  "heredoc delim vide (<<[espace])" $'cat << \nFOO'
check  "heredoc delim newline direct"    $'cat <<\nFOO'
vcheck "heredoc double quote delim"      $'cat <<"STOP"\n$HOME\nSTOP'
vcheck "heredoc single quote delim"      $'cat <<\'STOP\'\n$HOME\nSTOP'

# ── Contenu fou ──
vcheck "heredoc contenu vide"            $'cat <<EOF\nEOF'
vcheck "heredoc plusieurs lignes vides"  $'cat <<EOF\n\n\n\nEOF'
vcheck "heredoc avec backslash"          $'cat <<EOF\nhell\\o world\nEOF'
vcheck "heredoc avec tab"                $'cat <<EOF\nhello\tworld\nEOF'
vcheck "heredoc avec quotes dans corp"   $'cat <<EOF\n"hello"\n'"'"'world'"'"'\nEOF'
vcheck "heredoc avec dollar dans corp"   $'cat <<EOF\n\$HOME est $HOME\nEOF'
vcheck "heredoc special chars corps"     $'cat <<EOF\n!@#%^&*()_+=-\nEOF'
vcheck "heredoc 1000 lignes"             "$(python3 -c "lines=['cat <<EOF'] + ['line'+str(i) for i in range(1000)] + ['EOF']; print('\n'.join(lines))")"
vcheck "heredoc ligne qui ressemble delim" $'cat <<END\nENDnotit\nnotEND\nENDX\nEND'
vcheck "heredoc contenu = délimiteur-1c"  $'cat <<ABC\nAB\nABCD\nABC\nABC'
vcheck "heredoc ligne quasi-delim space"  $'cat <<EOF\nEOF \nEOF'
vcheck "heredoc pipe dans corps"          $'cat <<EOF\necho hi | cat\nEOF'
vcheck "heredoc redir dans corps"         $'cat <<EOF\necho > file\nEOF'

# ── Heredoc + pipeline / redirections ──
check  "heredoc | grep | wc"             $'cat <<EOF | grep hello | wc -l\nhello world\nno match\nhello again\nEOF'
check  "heredoc > fichier puis cat"      $'cat <<EOF > /tmp/ra_hd_out.txt\nhello heredoc\nEOF\ncat /tmp/ra_hd_out.txt\nrm -f /tmp/ra_hd_out.txt'
check  "heredoc >> append"               $'cat <<EOF >> /tmp/ra_hd_app.txt\nfirst\nEOF\ncat <<EOF >> /tmp/ra_hd_app.txt\nsecond\nEOF\ncat /tmp/ra_hd_app.txt\nrm -f /tmp/ra_hd_app.txt'
check  "heredoc entre deux pipes"        $'echo start | cat <<EOF | wc -l\nmiddle line\nEOF'
vcheck "heredoc + redir in (conflit)"    $'echo hi > /tmp/ra_hdin.txt\ncat <<EOF < /tmp/ra_hdin.txt\nhello\nEOF\nrm -f /tmp/ra_hdin.txt'
check  "heredoc pipé vers grep"          $'cat <<EOF | grep -c line\nline one\nno match\nline two\nEOF'

# ── Plusieurs heredocs ──
check  "deux heredocs séquentiels"       $'cat <<A\nfirst\nA\ncat <<B\nsecond\nB'
vcheck "heredoc même delim 2x"           $'cat <<X\nhello\nX\ncat <<X\nworld\nX'
check  "heredoc pipe multiple"           $'cat <<A | cat <<B | cat\nfoo\nA\nbar\nB'
check  "heredoc 5x séquentiel"           $'cat <<A\n1\nA\ncat <<B\n2\nB\ncat <<C\n3\nC\ncat <<D\n4\nD\ncat <<E\n5\nE'
vcheck "cat <<A <<B (double heredoc 1)"  $'cat <<A <<B\nlineA\nA\nlineB\nB'

# ── Heredoc et comportements $? ──
vcheck "heredoc puis echo \$?"           $'cat <<EOF\nhello\nEOF\necho $?'
check  "heredoc fail puis echo \$?"      $'cat <<EOF | invalidcmd\nhello\nEOF\necho $?'
check  "heredoc syntaxe err puis \$?"    $'cat <<EOF\nhello\nEOF\nls |\necho $?'

# ── Heredoc + signaux (via sigtest déjà défini) ──
sigtest "heredoc sans terminateur ^C"    "cat <<NOTERM"                         0.3
sigtest "heredoc partiel + pipe ^C"      $'cat <<EOF | cat\nhello'              0.3
sigtest "heredoc 2 niveaux ^C"           $'cat <<A | cat <<B\nlineA\nA\nlineB'  0.3

# ══════════════════════════════════════════════
section "[20] PATH POISONNING — FAUX BINAIRES"
# ══════════════════════════════════════════════

# Crée un répertoire de faux binaires
_FAKEBIN="/tmp/ra_fakebin_$$"
mkdir -p "$_FAKEBIN"

# Faux binaires variés
printf '#!/bin/sh\nexit 42\n'                            > "$_FAKEBIN/fakeexit42"
printf '#!/bin/sh\necho "stdout"\necho "err" >&2\nexit 2\n' > "$_FAKEBIN/fakeboth"
printf '#!/bin/sh\nrm -- "$0"\necho "self-deleted"\n'    > "$_FAKEBIN/selfdelete"
printf '#!/bin/sh\nfor i in 1 2 3 4 5 6 7 8 9 10; do echo line$i; done\n' > "$_FAKEBIN/fakeloop"
printf '#!/bin/sh\nyes hello | head -n 500\n'            > "$_FAKEBIN/bigout"
printf '#!/bin/sh\ncat /dev/null\n'                      > "$_FAKEBIN/fakenull"
printf '#!/bin/sh\necho $#\n'                            > "$_FAKEBIN/argcount"
printf '#!/bin/sh\necho $@\n'                            > "$_FAKEBIN/printargs"
printf '#!/bin/sh\nexport INJECTED=pwned\necho $INJECTED\n' > "$_FAKEBIN/envmodify"
printf '#!/bin/sh\nsleep 10\n'                           > "$_FAKEBIN/fakesleep"
# Shadowers de builtins
printf '#!/bin/sh\nexit 99\n'                            > "$_FAKEBIN/echo"
printf '#!/bin/sh\nexit 88\n'                            > "$_FAKEBIN/exit"
printf '#!/bin/sh\nexit 77\n'                            > "$_FAKEBIN/cd"
printf '#!/bin/sh\nexit 66\n'                            > "$_FAKEBIN/export"
printf '#!/bin/sh\nexit 55\n'                            > "$_FAKEBIN/unset"
printf '#!/bin/sh\nexit 44\n'                            > "$_FAKEBIN/env"
printf '#!/bin/sh\nexit 33\n'                            > "$_FAKEBIN/pwd"
# Exécutable vide (script sans contenu)
printf ''                                                > "$_FAKEBIN/emptyexec"
# Script sans shebang
printf 'echo noshebang\n'                                > "$_FAKEBIN/noshebang"
chmod +x "$_FAKEBIN"/*

_FP="$_FAKEBIN"

# ── Builtins ne doivent pas être shadowed par PATH ──
check  "echo builtin > shadow echo"  "$(printf 'export PATH=%s:$PATH\necho hello\necho $?' "$_FP")"
check  "exit builtin > shadow exit"  "$(printf 'export PATH=%s:$PATH\necho before\nexit 0' "$_FP")"
check  "cd builtin > shadow cd"      "$(printf 'export PATH=%s:$PATH\ncd /tmp\npwd' "$_FP")"
check  "export builtin > shadow"     "$(printf 'export PATH=%s:$PATH\nexport TESTV=ok\necho $TESTV' "$_FP")"
check  "unset builtin > shadow"      "$(printf 'export PATH=%s:$PATH\nexport UV=x\nunset UV\necho $UV' "$_FP")"
check  "env builtin > shadow"        "$(printf 'export PATH=%s:$PATH\nenv | grep -c PATH' "$_FP")"
check  "pwd builtin > shadow"        "$(printf 'export PATH=%s:$PATH\npwd' "$_FP")"

# ── Faux binaires dans PATH ──
vcheck "fake exit 42 dans PATH"      "$(printf 'export PATH=%s:$PATH\nfakeexit42\necho $?' "$_FP")"
vcheck "fake both stdout+stderr"     "$(printf 'export PATH=%s:$PATH\nfakeboth' "$_FP")"
vcheck "fake self-delete"            "$(printf 'export PATH=%s:$PATH\nselfdelete' "$_FP")"
vcheck "fake loop output"            "$(printf 'export PATH=%s:$PATH\nfakeloop' "$_FP")"
vcheck "fake bigout | head"          "$(printf 'export PATH=%s:$PATH\nbigout | head -n 5' "$_FP")"
vcheck "fake null (no output)"       "$(printf 'export PATH=%s:$PATH\nfakenull' "$_FP")"
vcheck "argcount 0 args"             "$(printf 'export PATH=%s:$PATH\nargcount' "$_FP")"
vcheck "argcount 5 args"             "$(printf 'export PATH=%s:$PATH\nargcount a b c d e' "$_FP")"
vcheck "printargs hello world"       "$(printf 'export PATH=%s:$PATH\nprintargs hello world' "$_FP")"
vcheck "empty exec (vide)"           "$(printf 'export PATH=%s:$PATH\nemptyexec' "$_FP")"
vcheck "no shebang script"           "$(printf 'export PATH=%s:$PATH\nnoshebang' "$_FP")"

# ── Pipe avec faux binaires ──
vcheck "fake | cat"                  "$(printf 'export PATH=%s:$PATH\nfakeloop | cat' "$_FP")"
vcheck "echo | fake"                 "$(printf 'export PATH=%s:$PATH\necho hello | fakenull' "$_FP")"
vcheck "fake | fake | fake"          "$(printf 'export PATH=%s:$PATH\nfakeloop | fakenull | argcount' "$_FP")"
check  "fake exit 42 | echo lol"     "$(printf 'export PATH=%s:$PATH\nfakeexit42 | echo lol\necho $?' "$_FP")"

# ── Chemin modifié en cours de route ──
check  "PATH=fake puis PATH normal"  "$(printf 'export PATH=%s\nls\nexport PATH=/usr/bin:/bin\nls /tmp | head -1' "$_FP")"
check  "PATH vide puis PATH rétabli" "$(printf 'export PATH=\nls\nexport PATH=/usr/bin:/bin\nls /tmp | head -1')"
check  "PATH=/nope puis absolu"      "$(printf 'export PATH=/nonexistent\nls\n/bin/ls /tmp | head -1')"

# ── SIGINT sur faux binaire bloquant ──
sigtest "fake sleep 10 ^C"           "$(printf 'export PATH=%s:$PATH\nfakesleep' "$_FP")"  0.4

# ── Nettoyage ──
rm -rf "$_FAKEBIN"

# ══════════════════════════════════════════════
section "[21] ENV -I — ENVIRONNEMENT VIDE"
# ══════════════════════════════════════════════
# Toutes ces comparaisons lancent mini ET bash avec env -i (env complètement vide)

# ── Variables systèmes à la racine ──
check_ei "env-i : PATH absent de env"            "env | grep -c '^PATH='"
check_ei "env-i : OLDPWD absent de env"          "env | grep -c '^OLDPWD='"
check_ei "env-i : PWD présent dans env"          "env | grep -c '^PWD='"
check_ei "env-i : PWD = répertoire courant"      "env | grep '^PWD='"

# ── Commandes de base fonctionnent ──
check_ei "env-i : echo hello"                    "echo hello"
check_ei "env-i : exit 0"                        "echo ok ; exit 0"
check_ei "env-i : exit code 0 au départ"         "echo \$?"
check_ei "env-i : cmd inconnue = exit 127"       "commande_inconnue_xyz_42 ; echo \$?"

# ── Après cd — mise à jour de PWD ──
check_ei "env-i : cd /tmp — PWD mis à jour"      "$(printf 'cd /tmp\nenv | grep "^PWD="')"
check_ei "env-i : cd /tmp — pwd correct"         "$(printf 'cd /tmp\npwd')"
check_ei "env-i : cd .. — PWD remonte"           "$(printf 'cd /tmp\ncd ..\nenv | grep "^PWD="')"
check_ei "env-i : cd / puis pwd"                 "$(printf 'cd /\npwd')"
check_ei "env-i : cd nonexistant — exit 1"       "$(printf 'cd /nonexistant_xyz_abc\necho \$?')"

# ── Après cd — apparition de OLDPWD ──
check_ei "env-i : cd /tmp — OLDPWD apparaît"     "$(printf 'cd /tmp\nenv | grep -c "^OLDPWD="')"
check_ei "env-i : cd /tmp — OLDPWD = dir initial" "$(printf 'cd /tmp\nenv | grep "^OLDPWD="')"
check_ei "env-i : double cd — OLDPWD suit"       "$(printf 'cd /tmp\ncd /\nenv | grep "^OLDPWD="')"
check_ei "env-i : triple cd — OLDPWD chain"      "$(printf 'cd /tmp\ncd /\ncd /var\nenv | grep "^OLDPWD="')"

# ── cd - ──
check_ei "env-i : cd - retour dir précédent"     "$(printf 'cd /tmp\ncd /\ncd -\npwd')"
check_ei "env-i : cd - sans OLDPWD = erreur"     "cd -"
check_ei "env-i : cd - exit 1 sans OLDPWD"       "$(printf 'cd -\necho \$?')"

# ── unset de variables spéciales ──
check_ei "env-i : unset PWD puis pwd"            "$(printf 'unset PWD\npwd')"
check_ei "env-i : unset PWD puis cd + PWD revient" "$(printf 'unset PWD\ncd /tmp\nenv | grep -c "^PWD="')"
check_ei "env-i : unset PWD puis cd /tmp PWD=?"  "$(printf 'unset PWD\ncd /tmp\nenv | grep "^PWD="')"

# ── export dans env vide ──
check_ei "env-i : PWD visible dans export"       "export | grep -c 'PWD'"
check_ei "env-i : PATH absent de export (env-i)" "export | grep -c '^PATH='"

# ── Variables utilisateur dans env vide ──
check_ei "env-i : export MYVAR=hello"            "$(printf 'export MYVAR=hello\nenv | grep "^MYVAR="')"
check_ei "env-i : export MYVAR sans val — pas dans env" "$(printf 'export MYVAR\nenv | grep -c "^MYVAR="')"
check_ei "env-i : export MYVAR= — vide dans env" "$(printf 'export MYVAR=\nenv | grep "^MYVAR="')"
check_ei "env-i : unset var — disparaît de env"  "$(printf 'export MYVAR=hello\nunset MYVAR\nenv | grep -c "^MYVAR="')"

# ── Pipes + redirections dans env vide ──
check_ei "env-i : pipe echo | cat"               "echo hello | cat"
check_ei "env-i : redirect out"                  "echo hi > /tmp/ra_ei_out_$$ ; cat /tmp/ra_ei_out_$$ ; rm -f /tmp/ra_ei_out_$$"
check_ei "env-i : heredoc basique"               $'cat <<EOF\nhello\nEOF'

# ══════════════════════════════════════════════
section "[22] COMPLÉMENTS DOCUMENT 800"
# ══════════════════════════════════════════════

# ── Commandes d'un seul caractère ──
check  "/ seul (Is a directory)"             "/"
check  "// seul (Is a directory)"            "//"
check  "- seul (cmd not found)"              "-"

# ── Echo — variantes de -n ──
check  "echo -nHola (flag collé au texte)"   "echo -nHola"
check  "echo Hola -n (flag après texte)"     "echo Hola -n"
check  "echo --------n"                      "echo --------n"

# ── Expansion variable — terminateurs inhabituels ──
check  "echo \$9HOME (param positif + texte)" "echo \$9HOME"
check  "echo \$HOME% (% termine le nom)"     "echo \$HOME%"
check  "echo \$: (char non-ident)"           "echo \$:"
check  "echo \$= (char non-ident)"           "echo \$="
check  "echo \$:\$= concat | cat -e"         'echo $:$= | cat -e'

# ── Exit avec guillemets ──
check  "exit \"666\" (double quotes)"        'exit "666"'
check  "exit '6'66 (single + bare)"          "exit '6'66"
check  "exit '2'66'32'"                      "exit '2'66'32'"
check  "exit '666'\"666\"666 (mix 3)"        "exit '666'\"666\"666"

# ── Pipes : echo ignore son stdin ──
check  "echo hola | echo que tal"            "echo hola | echo que tal"
check  "echo oui|non|hola | grep oui"        "echo oui | echo non | echo hola | grep oui"
check  "echo hola | echo non | grep hola"    "echo hola | echo non | grep hola"

# ── Redirection avant le nom de commande ──
check  "> file echo hola (redir avant cmd)"  $'> /tmp/ra_precmd.txt echo hola\ncat /tmp/ra_precmd.txt\nrm -f /tmp/ra_precmd.txt'
check  ">> file echo hola (append avant)"    $'>> /tmp/ra_precmd2.txt echo world\ncat /tmp/ra_precmd2.txt\nrm -f /tmp/ra_precmd2.txt'

# ── Heredoc sans espace entre << et délimiteur ──
check  "<<EOF sans commande"                 $'<<EOF\nhello\nEOF'
vcheck "cat<<EOF sans espace (avec contenu)" $'cat<<EOF\nhello world\nEOF'

# ── Unset avec arg invalide suivi d'arg valide ──
check  "unset \"\" VAR — exit code"          $'export _RA_UST=x\nunset "" _RA_UST\necho $?'
check  "unset \"\" VAR — var disparaît"      $'export _RA_UST2=x\nunset "" _RA_UST2\nenv | grep -c "^_RA_UST2="'

# ── Export — espace autour du signe = ──
check  "export VAR =val (espace avant =)"    $'export _RA_SP1 =bonjour\necho $?'
check  "export VAR= val (espace après =)"    $'export _RA_SP2= bonjour\necho $?'

# ══════════════════════════════════════════════
section "[23] SYNTAX ERRORS — PIPE ET REDIRECT INVALIDES"
# ══════════════════════════════════════════════
check  "| | double pipe vide"                "| |"
check  "| | | triple pipe vide"              "| | |"
check  "| \$"                                "| \$"
check  ">>> triple chevron"                  ">>>"
check  "cat    <| ls"                        "cat    <| ls"
check  "echo hi | >"                         "echo hi | >"
check  "echo hi | > >>"                      "echo hi | > >>"
check  "echo hi | < |"                       "echo hi | < |"
check  "echo hi |   |"                       "echo hi |   |"
check  "printf | | ls (syntax)"              "printf 'Err!' | | ls"
check  "printf < | ls (syntax)"             "printf 'Err!' < | ls"
check  "printf >> | ls (syntax)"            "printf 'Err!'  >> | ls"
check  "printf | > file (syntax)"           "printf 'Err!' | > /dev/null"
check  "printf |> file (syntax)"            "printf 'Err!' |> /dev/null"
check  ">x cmd | (syntax)"                  "> /dev/null printf 'Err!' |"
check  "| >x cmd (syntax)"                  "| > /dev/null printf 'Err!'"
check  ">x cmd > (syntax)"                  "> /dev/null printf 'Err!' >"
check  ">x cmd << (syntax)"                 "> /dev/null printf 'Err!' <<"
check  "echo '>' test '<'"                  "echo '>' test '<'"
check  "echo '>>'"                          "echo '>>'"
check  "echo '<<'"                          "echo '<<'"
check  "echo '>test<'"                      "echo '>test<'"
check  "echo '>test'"                       "echo '>test'"
check  "echo 'test<'"                       "echo 'test<'"
check  "echo \">\""                         'echo ">"'
check  "echo \"<\""                         'echo "<"'
check  "echo \">test<\""                    'echo ">test<"'

# ══════════════════════════════════════════════
section "[24] ECHO — CAS AVANCÉS"
# ══════════════════════════════════════════════
check  "echo hello'world' (adjacent)"       "echo hello'world'"
check  "echo hello\"\"world (adj dquote)"   'echo hello""world'
check  "echo ''b (empty+word)"              "echo ''b"
check  "echo '' b (space)"                  "echo '' b"
check  "echo '' ''x"                        "echo '' ''x"
check  "echo -n \$USER -n hello"            'echo -n $USER -n hello'
check  "echo test -n (flag last)"           "echo test -n"
check  "echo -nns -n test"                  "echo -nnnnnnnnnnnnnn -nns -n test"
check  "echo -nnn -n test"                  "echo -nnnnnnnnnnnnnn -nnn -n test"
check  "echo -nnnnnnnnnnnnnn1"              "echo -nnnnnnnnnnnnnn1 salut"
check  "echo -n multiple args"              "echo -n a b c d e"
check  "echo -n -n -n hello"               "echo -n -n -n hello"
check  "echo str1 empty str3"              'echo str1  "" str3'
check  "echo Ichi Ni San | cat -e"         "echo Ichi Ni San Yon Go | cat -e"
check  "echo '|' test"                     "echo '|' test"
check  "echo '>test '"                     "echo '>test '"
check  "echo ' test <'"                    "echo ' test <'"
check  "echo '> >> < * ? | ; <<'"         "echo '> >> < * ? | ; [ ] || && ( }) & # \$ \ <<'"
check  "echo \"exit_code->\$? user->\$USER\"" 'echo "exit_code ->$? user ->$USER"'
check  "echo --n (not a flag)"              "echo --n"

# ══════════════════════════════════════════════
section "[25] VARIABLES — CAS AVANCÉS"
# ══════════════════════════════════════════════
check  "echo \$EMPYT (var vide)"            "echo \$EMPYT"
check  "echo \$EMPYT    abc"               "echo \$EMPYT    abc"
check  "echo \$EMPYT abc"                  "echo \$EMPYT abc"
check  "echo \$EMPYT abc \$EMPTY"           "echo \$EMPYT abc \$EMPTY"
check  "\$EMPTY echo \$EMPYT abc"           "\$EMPTY echo \$EMPYT abc"
check  "echo \$USER_\$USER"                "echo \$USER_\$USER"
check  "printf \"\$USER\\n\""              'printf "$USER\n"'
check  "printf \$?"                        "printf \$?"
check  "printf \$??"                       "printf \$??"
check  "printf \$??? \$?? \$?"             "printf \$??? \$?? \$?"
check  "echo \$?HELLO"                     "echo \$?HELLO"
check  "echo \$ USER (dollar space)"       "echo \$ USER"
check  "echo \$USER\$ (trail dollar)"      "echo \$USER\$"
check  "echo \"\$USER\$\""                 'echo "$USER$"'
check  "echo \"\$USER \$\""               'echo "$USER $"'
check  "echo \$JENEXISTEPAS"               "echo \$JENEXISTEPAS"
check  "echo \$ JENEXISTEPAS"              "echo \$ JENEXISTEPAS"
check  "expr \$?+\$? chain"               $'true\nexpr $? + $?\nexpr $? + $?'
check  "echo \$USER\$USER (concat)"        "echo \$USER\$USER"
check  "echo \$USER multiple"              "echo \$USER \$USER \$USER \$USER \$USER"
check  "printf \"\$USER\$USER\""           'printf "$USER$USER"'
check  "echo '\$HOME' single no expand"    "echo '\$HOME'"
check  "echo \$\$ pid | wc -c"             "echo \$\$ | wc -c"
check  "echo \$\$\$\$\$\$... | wc -l"     "echo \$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$\$ | wc -l"
check  "echo \$ seul"                      "echo \$"

# ══════════════════════════════════════════════
section "[26] QUOTES — COMBINAISONS AVANCÉES"
# ══════════════════════════════════════════════
check  "prin\"tf\" \$USER (split cmd)"     'prin"tf" $USER'
check  "\"printf\" \$USER"                '"printf" $USER'
check  "pri\"tf \$USER\" (quote mid)"      'pri"tf $USER"'
check  "printf \$\"hello\" (dollar-dquote)" 'printf $"hello"'
check  "echo\$USER (no space)"             "echo\$USER"
check  "echo '' \"\"  (both empty)"        'echo '"'"''"'"' ""'
check  "echo '\$?' single"                 "echo '\$?'"
check  "echo ''\$USER'' (adj)"             "echo ''\$USER''"
check  "echo '''\$USER''' (3 quotes)"      "echo '''\$USER'''"
check  "echo \"\$\" dquote dollar"         'echo "$"'
check  "echo '\$' squote dollar"           "echo '\$'"
check  "echo alt quotes a\"b\"c\"d\""      "echo 'a'\"b\"'c'\"d\""
check  "echo \" \" (space only)"           'echo " "'
check  "echo \"    \" (spaces)"            'echo "    "'
check  "echo \"        \" (many spaces)"   'echo "        "'
check  "echo '    ' (squote spaces)"       "echo '    '"
check  "echo '        ' (squote 8sp)"      "echo '        '"
check  "echo \"\$PWD\" expand"             'echo "$PWD"'
check  "printf \"\$USER\$USER''\""         "printf \"\$USER\$USER'' = ' \$L ANG '\""
check  "echo seul"                         "echo"

# ══════════════════════════════════════════════
section "[27] EXPORT / UNSET — EDGE CASES"
# ══════════════════════════════════════════════
check  "export ABC puis env grep"          $'export ABC\nenv | grep "^ABC" | head -1'
check  "export+unset no print"             $'export NDACUNH=42\nunset NDACUNH\nprintf ":%s" "$NDACUNH"'
check  "export hello (no val)"             "export hello"
check  "export A- (invalid name)"          "export A-"
check  "export HELLO=123 A (mixed)"        "export HELLO=123 A"
check  "export HELLO=\"123 A-\""           'export HELLO="123 A-"'
check  "export hello world"               "export hello world"
check  "export HELLO-=123 (invalid)"       "export HELLO-=123"
check  "export = (invalid)"               "export ="
check  "export 123 (invalid)"             "export 123"
check  "export SLS='/bin/ls'"             $"export SLS='/bin/ls'\n/bin/ls /tmp | head -1"
check  "export TRES pipe env grep"         "export UNO=1 DOS-2 TRES=3 | env | grep TRES"
check  "export ABCD +=val (space)"         $'export ABCD=abcd\nexport ABCD +=ndacunh\nenv | grep "^ABCD"'
check  "export ABCD+= ndacunh"             $'export ABCD=abcd\nexport ABCD+= ndacunh\nenv | grep "^ABCD"'
check  "export ABCD =abcd (space=)"        $'export ABCD =abcd\nenv | grep "^ABCD"'
check  "export ABCD= abcd (=space)"        $'export ABCD= abcd\nenv | grep "^ABCD"'
check  "export ABCD=Hello; ABCD =x"        $'export ABCD=Hello\nexport ABCD =abcd\nenv | grep "^ABCD"'
check  "export ABCD=Hello; ABCD= x"        $'export ABCD=Hello\nexport ABCD= abcd\nenv | grep "^ABCD"'
check  "unset HELLO= (invalid)"            "unset HELLO="
check  "unset (no args)"                   "unset"
check  "unset HELLO1 HELLO2 multi"         "unset HELLO1 HELLO2"
check  "unset HOME; echo \$HOME"           $'unset HOME\necho $HOME'
check  "export A=supra; unset A"           $'export A=suprapack\necho a $A\nunset A\necho a $A'
check  "export HELLO=abc; unset HELLO"     $'export HELLO=abc\nunset HELLO'
check  "export HELL HELLOO no match"       $'export HELLO=abc\nunset HELL\nunset HELLOO\nprintf ":%s" "$HELLO"'

# ══════════════════════════════════════════════
section "[28] EXIT — EDGE CASES"
# ══════════════════════════════════════════════
check  "exit 123"                          "exit 123"
check  "exit 256 (wrap 0)"                "exit 256"
check  "exit +100 (signed plus)"          "exit +100"
check  "exit -100 (negative)"             "exit -100"
check  "exit hello (non-num)"             "exit hello"
check  "exit 42 world (too many args)"    "exit 42 world"
check  "exit 13 | exit 14 (dans pipe)"    "exit 13 | exit 14"
check  "exit MAX_INT64"                   "exit 9223372036854775807"
check  "exit MAX_INT64+1 (overflow)"      "exit 9223372036854775808"
check  "exit -MAX_INT64"                  "exit -9223372036854775807"
check  "exit -MAX_INT64-1"               "exit -9223372036854775808"
check  "exit -MAX_INT64-2 (underflow)"   "exit -9223372036854775809"
check  "exit \"+100\" (quoted)"           'exit "+100"'
check  "exit +\"100\" (mixed quote)"      'exit +"100"'
check  "exit \"-100\" (quoted neg)"       'exit "-100"'
check  "exit -\"100\" (dash+quote)"       'exit -"100"'

# ══════════════════════════════════════════════
section "[29] HEREDOC — EDGE CASES"
# ══════════════════════════════════════════════
vcheck "heredoc cat -e simple"             $'<< end cat -e\nsimple\ntest\nend'
vcheck "heredoc AH content"               $'<< AH cat -e\nsimple\ntest\nend\nAH'
vcheck "heredoc lignes vides"             $'<< AH cat -e\nsimple\n\n\n\nend\nAH'
vcheck "heredoc pipe | grep"              $'<< AH cat -e | grep -o simple\nsimple\nend\nAH'
vcheck "heredoc \"EOF\" expand \$USER"    $'<< "EOF" cat -e\n$USER\nEOF'
vcheck "heredoc 'EOF' no expand \$USER"   $'<< '"'"'EOF'"'"' cat -e\n$USER\nEOF'
vcheck "heredoc \"EOF\" no expand txt"    $'<< "EOF" cat -e\nnda-cuhn\nEOF'
vcheck "heredoc 'EOF' literal txt"        $'<< '"'"'EOF'"'"' cat -e\nnda-cuhn\nEOF'
vcheck "cat << here -e (flags après)"     $'cat << here -e\nhello\nhere'
vcheck "heredoc + newline après end"       $'<< end cat -e\nsimple\ntest\nend\n'
vcheck "heredoc AH + newline"             $'<< AH cat -e\nsimple\ntest\nend\nAH\n'
vcheck "heredoc expand dquote + newline"  $'<< "EOF" cat -e\n$USER\nEOF\n'
vcheck "heredoc no expand squote + nl"    $'<< '"'"'EOF'"'"' cat -e\n$USER\nEOF\n'
check  "<<EOF sans commande"              $'<<EOF\nhello\nEOF'
vcheck "cat<<EOF sans espace"             $'cat<<EOF\nhello world\nEOF'

# ══════════════════════════════════════════════
section "[30] PWD — EDGE CASES"
# ══════════════════════════════════════════════
check  "pwd seul"                          "pwd"
check  "pwd | cat -e"                      "pwd | cat -e"
check  "pwd . (arg point)"                 "pwd ."
check  "pwd .. (arg double point)"         "pwd .."
check  "printf a | pwd | cat -e"           "printf a | pwd | cat -e"
check  "clear | pwd"                       "clear | pwd"
check  "clear | pwd | cat -e"             "clear | pwd | cat -e"
check  "clear | pwd . | cat -e"           "clear | pwd . | cat -e"
check  "pwd; cd /tmp; pwd"                $'pwd\ncd /tmp\npwd'
check  "cd /tmp; pwd; cd -; pwd"          $'cd /tmp\npwd\ncd -\npwd'

# ══════════════════════════════════════════════
section "[31] REDIRECTIONS — AVANCÉES"
# ══════════════════════════════════════════════
check  "< /etc/hostname cat | md5sum"      "< /etc/hostname cat | md5sum"
check  "< nonexist cat | wc -c"           "< /nonexistent_xyz_ra31 cat | wc -c"
check  "< /etc/hostname | printf msg"      "< /etc/hostname | printf 'visible?'"
check  "< /dev/urandom head | wc -c"      "< /dev/urandom head -c 15 | wc -c"
check  "printf >/dev/null | cat -e"        "printf 'hello world' >/dev/null | cat -e"
check  ">/dev/null printf | cat -e"        ">/dev/null printf 'hello world' | cat -e"
check  ">/dev/stdout printf | cat -e"      ">/dev/stdout printf 'hello world' | cat -e"
check  "> /dev/stdout seul"               "> /dev/stdout"
check  ">> /dev/stdout seul"              ">> /dev/stdout"
check  "< /dev/stdout seul"               "< /dev/stdout"
check  "< /etc/hostname < /etc/os-release wc" "wc -w < /etc/hostname < /etc/os-release"
check  "ls | wc -w < /etc/hostname"       "ls | wc -w < /etc/hostname"
vcheck "printf append multi"              $'printf hello > /tmp/ra_a31.txt\nprintf world >> /tmp/ra_a31.txt\ncat /tmp/ra_a31.txt\nrm -f /tmp/ra_a31.txt'
check  "> file echo (redir avant cmd)"    $'> /tmp/ra_pre31.txt echo hola\ncat /tmp/ra_pre31.txt\nrm -f /tmp/ra_pre31.txt'
check  ">> file echo (append avant cmd)"  $'>> /tmp/ra_app31.txt echo world\ncat /tmp/ra_app31.txt\nrm -f /tmp/ra_app31.txt'
check  "cmd_not_found | wc -c"            "cmd_not_found_xyz_ra31 | wc -c"
check  "cat < nonexist | wc -c"           "cat < /nonexistent_xyz_ra31 | wc -c"
check  "< Makefile nonexist cmd | wc -c"  "< /etc/hostname cmd_not_found_xyz | wc -c"
check  "< /etc/hostname | printf voir?"   "< /etc/hostname | printf 'You see me?'"
check  "< /etc/hostname < /etc/hostname"  "< /etc/hostname < /etc/hostname cat"

# ══════════════════════════════════════════════
section "[32] COMMANDES DIVERSES"
# ══════════════════════════════════════════════
check  "\$PWD (run comme cmd)"             "\$PWD"
check  "\$EMPTY (empty var comme cmd)"     "\$EMPTY"
check  "\$EMPTY echo hi"                   "\$EMPTY echo hi"
check  "edsfdsf; echo error \$?"          $'edsfdsf\necho "error: $?"'
check  "ls | ls |ls | ls| ls (chain)"     "ls | ls |ls | ls| ls"
check  "/bin/ls | /usr/bin/cat -e"         "/bin/ls | /usr/bin/cat -e"
check  ".. | .. | .. (invalid cmds)"       ".. | .. | .."
check  "command_not_found | echo abc"      "command_not_found | echo 'abc'"
check  "command_not_found | cat"           "command_not_found | cat"
check  "true | false (exit code)"          "true | false"
check  "false | true (exit code)"          "false | true"
check  "false | false (both fail)"         "false | false"
check  "/bin/ls -la | head -5"             "/bin/ls -la | head -5"
check  "/bin/ls -l | wc -l"               "/bin/ls -l | wc -l"
check  "ls -l | cat -e | head -3"          "ls -l | cat -e | head -3"
check  "printf '%s' hello world"           "printf '%s' hello world"
check  "echo \"cat | cat > \$USER\""      'echo "cat Makefile | cat > $USER"'
check  "echo 'cat | cat > \$USER'"        "echo 'cat Makefile | cat > \$USER'"
vcheck "cat /dev/urandom | head | wc"      "cat /dev/urandom | head -c 15 | wc -c"
check  "echo \$?"                          "echo \$?"

# ══════════════════════════════════════════════
section "[33] ENV — FILTRAGE ET UNSET"
# ══════════════════════════════════════════════
check  "env | grep USER"                   "env | grep USER"
check  "env | grep HOME"                   "env | grep HOME"
check  "unset 6_a (invalid name)"          "unset 6_a"
check  "unset ndacunh (inexistant)"        "unset ndacunh"
check  "unset 0oui (invalid)"              "unset 0oui"
check  "unset PWD HERE; echo \$PWD"        $'unset PWD HERE\necho $PWD'
check  "unset PATH; /bin/ls /tmp"          $'unset PATH\n/bin/ls /tmp | head -1'
check  "unset PATH; ls (pas de PATH)"      $'unset PATH\nls'
check  "unset HOME; echo \$HOME"           $'unset HOME\necho $HOME'
check  "export GHOST=123 | env grep"       "export GHOST=123 | env | grep GHOST"
check  "env | grep -c PATH"                "env | grep -c PATH"
check  "env | grep USER | wc -l"           "env | grep USER | wc -l"
check  "export HELL HELLOO no match"       $'export HELLO=abc\nunset HELL\nunset HELLOO\necho $HELLO'
check  "export+unset: var disparaît"       $'export MYVAR33=hello\nunset MYVAR33\nenv | grep -c "^MYVAR33="'
check  "export MYVAR33= vide dans env"     $'export MYVAR33=\nenv | grep "^MYVAR33="'

# ══════════════════════════════════════════════
section "[34] EXTRA PIPE CHAINS ET EDGE CASES"
# ══════════════════════════════════════════════
check  "ls|ls|ls|ls|ls|ls|cat -e"          "ls|ls|ls|ls|ls|ls|cat -e"
check  "echo hello|cat -e (no space)"       "echo hello|cat -e"
check  "echo hello      |cat -e (spaces)"   "echo hello      |cat -e"
check  "echo hello|               cat -e"   "echo hello|               cat -e"
check  "echo hello | cat -e | cat -e"       "echo hello | cat -e | cat -e"
check  "echo abc | wc -c"                   "echo abc | wc -c"
check  "echo '' | cat -e"                   "echo '' | cat -e"
check  "echo '   ' | cat -e"               "echo '   ' | cat -e"
check  "ls | wc -l | cat"                   "ls | wc -l | cat"
check  "echo a | echo b | echo c"           "echo a | echo b | echo c"
check  "cat /etc/hostname | md5sum"          "cat /etc/hostname | md5sum"
check  "echo hello world | grep hello"       "echo hello world | grep hello"
check  "echo hello world | grep xyz"         "echo hello world | grep xyz"
check  "ls | cat | cat | cat | cat | cat"    "ls | cat | cat | cat | cat | cat"
check  "printf a | pwd | cat -e"             "printf a | pwd | cat -e"
check  "echo \"\$PWD\""                      'echo "$PWD"'
check  "echo '\$PWD'"                        "echo '\$PWD'"
check  "echo \"> >> < * ? | ; <<\" (dquote)" 'echo "> >> < * ? | ; [ ] || && ( }) & # $ \ <<"'
check  "ls|ls|ls|ls|ls|ls|ls|ls|ls|ls"      "ls|ls|ls|ls|ls|ls|ls|ls|ls|ls"
check  "echo \$USER | wc -c"                "echo \$USER | wc -c"

# ══════════════════════════════════════════════
printf "\n"
echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}  RECAP GLOBAL${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "${GREEN}PASS   : $TOTAL_PASS${NC}"
echo -e "${YELLOW}WARN   : $TOTAL_WARN${NC}"
echo -e "${RED}FAIL   : $TOTAL_FAIL${NC}"
echo -e "${RED}LEAKS  : $TOTAL_LEAK${NC}"
echo -e "${RED}CRASH  : $TOTAL_CRASH${NC}"

log ""
log "════════════════════════════════════════════════════"
log "  RECAP GLOBAL  ($(date '+%Y-%m-%d %H:%M:%S'))"
log "════════════════════════════════════════════════════"
log "  TOTAL TESTS : $TEST_NUM"
log "  PASS        : $TOTAL_PASS"
log "  FAIL        : $TOTAL_FAIL"
log "  LEAKS       : $TOTAL_LEAK"
log "  CRASH       : $TOTAL_CRASH"
log ""

# Nettoyage /tmp
rm -f /tmp/ra_out.txt /tmp/ra_app.txt /tmp/ra_m1.txt /tmp/ra_m2.txt \
      /tmp/ra_pr.txt /tmp/ra_ev.txt

# Nettoyage des fichiers créés dans le répertoire courant pendant les tests
_AFTER_FILES=$(ls -1 . 2>/dev/null | sort)
_CREATED=$(comm -13 <(echo "$_BEFORE_FILES") <(echo "$_AFTER_FILES"))
if [ -n "$_CREATED" ]; then
	echo -e "${YELLOW}[cleanup] fichiers créés par les tests — supprimés :${NC}"
	while IFS= read -r f; do
		echo -e "  ${YELLOW}$f${NC}"
		rm -f "$f"
	done <<< "$_CREATED"
fi
