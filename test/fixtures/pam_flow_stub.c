/* Test-only PAM module standing in for pam_fprintd.so, so the *control
 * flow* of the attempt stack install.sh writes (bin/lib.sh's
 * pam_fprintd_harden) can be tested in a container, where there is no
 * fingerprint reader. What's under test is libpam's own handling of the
 * bracketed control field - the jump/ignore/die actions - not anything about
 * fingerprints.
 *
 * Two module arguments:
 *
 *   mark=<name>  append <name> plus a newline to /tmp/pam-flow.log, so the
 *                test can see exactly which lines ran, in order
 *   ret=<code>   what to return: success | authinfo_unavail | auth_err |
 *                maxtries | abort - the outcomes pam_fprintd actually
 *                produces: a match; a bad scan or a timeout; an unrecognised
 *                verify result; the single no-match that max-tries=1 turns
 *                into PAM_MAXTRIES; and something genuinely broken
 *
 * Never installed anywhere real - only built and loaded inside
 * test/runtime-test.sh's throwaway container.
 */
#include <security/pam_modules.h>

#include <stdio.h>
#include <string.h>

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc,
                                    const char **argv) {
    (void)pamh;
    (void)flags;

    const char *mark = NULL;
    int ret = PAM_SUCCESS;

    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "mark=", 5) == 0) {
            mark = argv[i] + 5;
        } else if (strcmp(argv[i], "ret=success") == 0) {
            ret = PAM_SUCCESS;
        } else if (strcmp(argv[i], "ret=authinfo_unavail") == 0) {
            ret = PAM_AUTHINFO_UNAVAIL;
        } else if (strcmp(argv[i], "ret=auth_err") == 0) {
            ret = PAM_AUTH_ERR;
        } else if (strcmp(argv[i], "ret=maxtries") == 0) {
            ret = PAM_MAXTRIES;
        } else if (strcmp(argv[i], "ret=abort") == 0) {
            ret = PAM_ABORT;
        }
    }

    if (mark) {
        FILE *f = fopen("/tmp/pam-flow.log", "a");
        if (f) {
            fprintf(f, "%s\n", mark);
            fclose(f);
        }
    }
    return ret;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc,
                               const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
