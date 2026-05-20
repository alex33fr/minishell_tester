#!/bin/bash
# check_allowed.sh — vérifie les fonctions externes autorisées (sujet minishell 42)
# Usage: bash check_allowed.sh

cd "$(dirname "$0")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Fonctions autorisées par le sujet ──
ALLOWED=(
	readline rl_clear_history rl_on_new_line rl_replace_line rl_redisplay add_history
	printf malloc free write access open read close
	fork wait waitpid wait3 wait4
	signal sigaction sigemptyset sigaddset kill exit
	getcwd chdir stat lstat fstat unlink execve
	dup dup2 pipe opendir readdir closedir
	strerror perror isatty ttyname ttyslot ioctl getenv
	tcsetattr tcgetattr tgetent tgetflag tgetnum tgetstr tgoto tputs
)

# Variantes "hardened" du compilateur → mapped vers leur base
declare -A HARDENED_MAP
HARDENED_MAP=(
	["__printf_chk"]="printf"
	["__fprintf_chk"]="fprintf"
	["__sprintf_chk"]="sprintf"
	["__snprintf_chk"]="snprintf"
	["__memcpy_chk"]="memcpy"
	["__memmove_chk"]="memmove"
	["__strcpy_chk"]="strcpy"
	["__strcat_chk"]="strcat"
	["__strncat_chk"]="strncat"
	["__strncpy_chk"]="strncpy"
	["__read_chk"]="read"
	["__fread_chk"]="fread"
)

echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}  CHECK FONCTIONS AUTORISÉES — MINISHELL 42${NC}"
echo -e "${CYAN}================================================================${NC}"

# ── Collecte des .o du projet uniquement (hors libft) ──
mapfile -t OBJ_FILES < <(find obj/ -name "*.o" 2>/dev/null | sort)
if [ ${#OBJ_FILES[@]} -eq 0 ]; then
	echo -e "${RED}[ERREUR] Aucun .o dans obj/ — compilez d'abord (make)${NC}"
	exit 1
fi
echo -e "\n${BOLD}Fichiers .o analysés :${NC} ${#OBJ_FILES[@]} (hors libft)"

# ── Extraction des symboles externes non définis ──
# SYM_SRCS[sym] = "src1.c src2.c ..."
declare -A SYM_SRCS

for obj in "${OBJ_FILES[@]}"; do
	src=$(echo "$obj" | sed 's|^obj/||; s|\.o$|.c|')
	while IFS= read -r sym; do
		# Strip @GLIBC_x.x version suffix
		sym="${sym%%@*}"
		[[ -z "$sym" ]] && continue
		# Ignorer artefacts compilateur/linker avant tout
		[[ "$sym" == __* ]]                  && continue  # GCC internals (__stack_chk_fail, etc.)
		[[ "$sym" == *GLOBAL_OFFSET_TABLE_* ]] && continue  # GOT/PLT PIC artifact
		[[ "$sym" == *_chk ]]                && continue  # hardened variants
		# Strip leading underscore (some ABIs)
		clean="${sym#_}"
		[[ -z "$clean" ]] && continue
		SYM_SRCS["$clean"]+=" $src"
	done < <(nm -u "$obj" 2>/dev/null | awk '{print $NF}')
done

# ── Classification de chaque symbole ──
FORBIDDEN=()
declare -A FORBIDDEN_SRCS
declare -A USED_ALLOWED_MAP

is_allowed() {
	local name="$1"
	for a in "${ALLOWED[@]}"; do
		[[ "$name" == "$a" ]] && return 0
	done
	return 1
}

for sym in $(echo "${!SYM_SRCS[@]}" | tr ' ' '\n' | sort -u); do
	clean="$sym"

	# Ignorer : internals compilateur / runtime
	[[ "$clean" == __* ]]   && continue
	[[ "$clean" == _IO_* ]] && continue
	[[ "$clean" == _dl_* ]] && continue
	[[ "$clean" == _start  ]] && continue

	# Résoudre les variantes hardened
	mapped="${HARDENED_MAP[$clean]:-$clean}"

	# Ignorer : fonctions ft_* (libft autorisée)
	[[ "$clean" == ft_* ]] && continue

	# Ignorer : fonctions internes du projet (définies dans les .o du projet)
	# Un symbole défini localement dans un autre .o n'est pas externe
	is_defined=0
	for obj in "${OBJ_FILES[@]}"; do
		if nm "$obj" 2>/dev/null | awk '$2 ~ /^[TtDdBb]$/{print $NF}' | grep -qx "$clean"; then
			is_defined=1; break
		fi
	done
	[ $is_defined -eq 1 ] && continue

	# Vérifier si autorisé (avec le nom mappé si variante hardened)
	if is_allowed "$mapped"; then
		USED_ALLOWED_MAP["$mapped"]=1
	else
		FORBIDDEN+=("$clean")
		FORBIDDEN_SRCS["$clean"]="${SYM_SRCS[$sym]}"
	fi
done

# ══════════════════════════════════════════════
echo -e "\n${BOLD}[1] FONCTIONS NON AUTORISÉES${NC}"
if [ ${#FORBIDDEN[@]} -eq 0 ]; then
	echo -e "  ${GREEN}Aucune — OK${NC}"
else
	for sym in $(echo "${FORBIDDEN[@]}" | tr ' ' '\n' | sort -u); do
		echo -e "  ${RED}[INTERDIT]${NC} ${BOLD}${sym}${NC}"
		# Afficher les fichiers sources uniques
		srcs_seen=""
		for src in ${FORBIDDEN_SRCS[$sym]}; do
			[[ " $srcs_seen " == *" $src "* ]] && continue
			srcs_seen+=" $src"
			echo -e "             → ${YELLOW}${src}${NC}"
		done
	done
fi

# ══════════════════════════════════════════════
echo -e "\n${BOLD}[2] VARIABLES GLOBALES (max 1 autorisée pour signal)${NC}"
declare -A GLOBAL_SRCS

for obj in "${OBJ_FILES[@]}"; do
	src=$(echo "$obj" | sed 's|^obj/||; s|\.o$|.c|')
	while IFS= read -r line; do
		sym=$(echo "$line" | awk '{print $NF}')
		sym="${sym%%@*}"
		clean="${sym#_}"
		[[ -z "$clean" || "$clean" == __* ]] && continue
		GLOBAL_SRCS["$clean"]+=" $src"
	done < <(nm "$obj" 2>/dev/null | awk '$2 ~ /^[BD]$/')
done

GLOBAL_COUNT=${#GLOBAL_SRCS[@]}
if [ $GLOBAL_COUNT -eq 0 ]; then
	echo -e "  ${GREEN}0 variable globale — OK${NC}"
elif [ $GLOBAL_COUNT -eq 1 ]; then
	for g in "${!GLOBAL_SRCS[@]}"; do
		echo -e "  ${GREEN}1 variable globale (OK) :${NC} ${BOLD}$g${NC}"
		for src in ${GLOBAL_SRCS[$g]}; do
			echo -e "    → ${YELLOW}$src${NC}"
		done
	done
else
	echo -e "  ${RED}[ATTENTION] $GLOBAL_COUNT variables globales trouvées (max 1 autorisée) :${NC}"
	for g in "${!GLOBAL_SRCS[@]}"; do
		echo -e "  ${RED}  ${BOLD}$g${NC}"
		srcs_seen=""
		for src in ${GLOBAL_SRCS[$g]}; do
			[[ " $srcs_seen " == *" $src "* ]] && continue
			srcs_seen+=" $src"
			echo -e "    → ${YELLOW}$src${NC}"
		done
	done
fi

# ══════════════════════════════════════════════
echo -e "\n${BOLD}[3] FONCTIONS AUTORISÉES UTILISÉES${NC}"
USED_SORTED=$(echo "${!USED_ALLOWED_MAP[@]}" | tr ' ' '\n' | sort)
used_count=$(echo "$USED_SORTED" | grep -c .)
echo -e "  ${used_count} / ${#ALLOWED[@]} fonctions autorisées utilisées :"
while IFS= read -r u; do
	[ -n "$u" ] && echo -e "    ${GREEN}✓${NC} $u"
done <<< "$USED_SORTED"

# ══════════════════════════════════════════════
echo -e "\n${BOLD}[4] VÉRIFICATION #INCLUDE SUSPECTS${NC}"
SUSPICIOUS_HDRS=("string.h" "strings.h" "stdlib.h" "stdio.h" "ctype.h" "math.h" "time.h")
found_any=0
while IFS= read -r file; do
	for hdr in "${SUSPICIOUS_HDRS[@]}"; do
		if grep -q "#include.*<${hdr}>" "$file" 2>/dev/null; then
			echo -e "  ${YELLOW}[WARN]${NC} ${file} inclut <${hdr}>"
			echo -e "         → Vérifier que seules les fonctions autorisées y sont utilisées"
			found_any=1
		fi
	done
done < <(find . -name "*.c" -o -name "*.h" | grep -v libft | grep -v ".git")
[ $found_any -eq 0 ] && echo -e "  ${GREEN}Aucun header suspect — OK${NC}"

# ══════════════════════════════════════════════
echo -e "\n${CYAN}================================================================${NC}"
echo -e "${CYAN}  RECAP${NC}"
echo -e "${CYAN}================================================================${NC}"
if [ ${#FORBIDDEN[@]} -eq 0 ] && [ $GLOBAL_COUNT -le 1 ]; then
	echo -e "  ${GREEN}${BOLD}CONFORME AU SUJET${NC}"
else
	[ ${#FORBIDDEN[@]} -gt 0 ] && echo -e "  ${RED}${BOLD}${#FORBIDDEN[@]} fonction(s) non autorisée(s) à corriger${NC}"
	[ $GLOBAL_COUNT -gt 1 ] && echo -e "  ${RED}${BOLD}$GLOBAL_COUNT variables globales — max 1${NC}"
fi
echo ""
