/*
 * pam_tpm_keyring_authtok - injects a TPM-unsealed password into PAM_AUTHTOK
 * so a following "auth optional pam_gnome_keyring.so" can unlock the login
 * keyring even when the actual authentication was fingerprint-based (which
 * never produces a password PAM_AUTHTOK on its own).
 *
 * This module NEVER makes an authentication decision itself: it always
 * returns PAM_IGNORE, regardless of outcome. It must be listed with control
 * "optional" and placed after the real authenticating module (pam_fprintd.so)
 * and before "pam_gnome_keyring.so" in the auth stack. If it fails for any
 * reason (no sealed secret, TPM error, wrong PCR state), login proceeds
 * exactly as it would without this module - it only adds keyring auto-unlock,
 * it cannot subtract login capability.
 *
 * If PAM_AUTHTOK is already set (e.g. a real password was typed), this
 * module does nothing and leaves it alone.
 */

#define PAM_SM_AUTH

#include <security/pam_modules.h>
#include <security/pam_ext.h>

#include <fcntl.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define HELPER_PATH "/usr/local/sbin/tpm-keyring-unseal"
#define MAX_PW_LEN 4096

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags, int argc,
                                    const char **argv) {
    (void)flags;
    (void)argc;
    (void)argv;

    const void *existing = NULL;
    if (pam_get_item(pamh, PAM_AUTHTOK, &existing) == PAM_SUCCESS &&
        existing != NULL) {
        return PAM_IGNORE;
    }

    const char *user = NULL;
    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL) {
        return PAM_IGNORE;
    }

    struct passwd *pw = getpwnam(user);
    if (pw == NULL) {
        return PAM_IGNORE;
    }

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        return PAM_IGNORE;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(pipefd[0]);
        close(pipefd[1]);
        return PAM_IGNORE;
    }

    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);

        int devnull = open("/dev/null", O_WRONLY);
        if (devnull >= 0) {
            dup2(devnull, STDERR_FILENO);
            close(devnull);
        }

        char *const child_argv[] = {HELPER_PATH, (char *)user, NULL};
        char *const child_envp[] = {NULL};
        execve(HELPER_PATH, child_argv, child_envp);
        _exit(127);
    }

    close(pipefd[1]);

    char buf[MAX_PW_LEN];
    ssize_t total = 0;
    ssize_t n;
    while (total < (ssize_t)sizeof(buf) - 1) {
        n = read(pipefd[0], buf + total, sizeof(buf) - 1 - (size_t)total);
        if (n <= 0) {
            break;
        }
        total += n;
    }
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    if (total <= 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        memset(buf, 0, sizeof(buf));
        return PAM_IGNORE;
    }

    buf[total] = '\0';
    if (total > 0 && buf[total - 1] == '\n') {
        buf[total - 1] = '\0';
    }

    pam_set_item(pamh, PAM_AUTHTOK, buf);
    memset(buf, 0, sizeof(buf));

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
