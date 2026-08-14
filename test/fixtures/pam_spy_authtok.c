/* Test-only PAM module: writes whatever PAM_AUTHTOK currently holds to
 * /tmp/spy-authtok, using the exact same pam_get_item() call the real
 * pam_gnome_keyring.so makes. Placed right after
 * pam_tpm_keyring_authtok.so in a test auth stack, this directly proves
 * whether that module's pam_set_item() call actually took effect for a
 * downstream module - the thing that matters in production - without
 * depending on pam_exec.so's expose_authtok semantics (which turned out
 * not to behave as expected in a stripped-down container image, with no
 * man page available to double check against).
 *
 * Never installed anywhere real - only built and loaded inside
 * test/runtime-test.sh's throwaway container.
 */
#include <security/pam_modules.h>

#include <stdio.h>

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc,
                                    const char **argv) {
    (void)flags;
    (void)argc;
    (void)argv;

    const void *tok = NULL;
    pam_get_item(pamh, PAM_AUTHTOK, &tok);

    FILE *f = fopen("/tmp/spy-authtok", "w");
    if (f) {
        if (tok) {
            fputs((const char *)tok, f);
        }
        fclose(f);
    }
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
