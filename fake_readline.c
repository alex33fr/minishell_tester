/* ************************************************************************** */
/*                                                                            */
/*   fake_readline.c                                                          */
/*                                                                            */
/*   Intercepts readline() via LD_PRELOAD to replace the minishell prompt     */
/*   with a fixed known string "MINIT: ".                                     */
/*   This lets the tester strip prompt lines from stdout regardless of what   */
/*   prompt the student's minishell uses.                                      */
/*                                                                            */
/* ************************************************************************** */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stddef.h>

char	*readline(const char *prompt)
{
	static char	*(*real_rl)(const char *) = NULL;

	(void)prompt;
	if (!real_rl)
		real_rl = dlsym(RTLD_NEXT, "readline");
	return (real_rl("MINIT: "));
}
