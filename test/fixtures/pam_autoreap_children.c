/* Test-only PAM module: sets SIGCHLD to SIG_IGN, which makes the kernel
 * reap this process's children the moment they exit, so a later
 * waitpid() for a specific child fails with ECHILD.
 *
 * Stands in for a login process (a display manager, a session worker)
 * that does the same thing to avoid collecting zombies itself.
 * pam_tpm_keyring_authtok.so cannot control the process it is loaded
 * into, so it has to survive that: with no confirmable exit status for
 * the unseal helper it must leave PAM_AUTHTOK alone rather than trust
 * output that may have come from a helper killed mid-write. Placed above
 * it in a test auth stack, this module creates exactly that condition.
 *
 * Never installed anywhere real - only built and loaded inside
 * test/runtime-test.sh's throwaway container.
 */
#define _POSIX_C_SOURCE 200809L

#include <security/pam_modules.h>

#include <signal.h>

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc,
                                    const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;

    signal(SIGCHLD, SIG_IGN);
    return PAM_IGNORE;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags, int argc,
                               const char **argv) {
    (void)pamh;
    (void)flags;
    (void)argc;
    (void)argv;
    return PAM_SUCCESS;
}
