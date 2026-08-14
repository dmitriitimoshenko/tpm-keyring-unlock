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

/* Must come before any #include: without it, struct sigaction/sigaction()/
 * sigemptyset()/kill() are only visible because plain `gcc` defaults to
 * GNU mode and defines this implicitly - under -std=c11/c99 (what IDE
 * IntelliSense / a stricter or non-glibc libc may assume) they silently
 * disappear. This makes the POSIX.1-2008 declarations unconditional. */
#define _POSIX_C_SOURCE 200809L

#define PAM_SM_AUTH

#include <security/pam_modules.h>
#include <security/pam_ext.h>

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <syslog.h>
#include <unistd.h>

/* Overridable at compile time (-DHELPER_PATH=... / -DHELPER_TIMEOUT_SECS=...)
 * strictly for the test suite under test/, so it can point at a throwaway
 * fake helper and use a short timeout instead of waiting out the real one.
 * Production builds (install.sh) never pass these flags, so they always
 * get the real path and the real 15s budget. */
#ifndef HELPER_PATH
#define HELPER_PATH "/usr/local/sbin/tpm-keyring-unseal"
#endif
#define MAX_PW_LEN 4096
#ifndef HELPER_TIMEOUT_SECS
#define HELPER_TIMEOUT_SECS 15
#endif

static volatile sig_atomic_t g_timed_out = 0;

static void on_alarm(int signo) {
    (void)signo;
    g_timed_out = 1;
}

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
        pam_syslog(pamh, LOG_ERR, "pam_get_user() failed");
        return PAM_IGNORE;
    }

    struct passwd *pw = getpwnam(user);
    if (pw == NULL) {
        pam_syslog(pamh, LOG_ERR, "getpwnam(%s) failed", user);
        return PAM_IGNORE;
    }

    pam_syslog(pamh, LOG_INFO,
               "PAM_AUTHTOK not set yet, attempting TPM keyring unseal for "
               "user %s", user);

    int pipefd[2];
    if (pipe(pipefd) != 0) {
        pam_syslog(pamh, LOG_ERR, "pipe() failed: %s", strerror(errno));
        return PAM_IGNORE;
    }

    pid_t pid = fork();
    if (pid < 0) {
        pam_syslog(pamh, LOG_ERR, "fork() failed: %s", strerror(errno));
        close(pipefd[0]);
        close(pipefd[1]);
        return PAM_IGNORE;
    }

    if (pid == 0) {
        close(pipefd[0]);
        dup2(pipefd[1], STDOUT_FILENO);
        close(pipefd[1]);

        /* stderr is intentionally left as-is (inherited from the login
         * process, which already goes to the journal) so tpm2-tools' own
         * error output is visible for diagnosis instead of silently
         * discarded. */

        char *const child_argv[] = {HELPER_PATH, (char *)user, NULL};
        char *const child_envp[] = {NULL};
        execve(HELPER_PATH, child_argv, child_envp);
        _exit(127);
    }

    close(pipefd[1]);

    /* Bound how long a hung TPM call can block the login prompt. SA_RESTART
     * is deliberately not set, so the alarm interrupts read()/waitpid()
     * with EINTR instead of silently retrying them. */
    struct sigaction sa, old_sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_alarm;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGALRM, &sa, &old_sa);
    g_timed_out = 0;
    alarm(HELPER_TIMEOUT_SECS);

    char buf[MAX_PW_LEN];
    ssize_t total = 0;
    ssize_t n;
    while (total < (ssize_t)sizeof(buf) - 1) {
        n = read(pipefd[0], buf + total, sizeof(buf) - 1 - (size_t)total);
        if (n < 0) {
            if (errno == EINTR && !g_timed_out) {
                continue;
            }
            break;
        }
        if (n == 0) {
            break;
        }
        total += n;
    }
    close(pipefd[0]);

    if (g_timed_out) {
        kill(pid, SIGKILL);
    }

    int status = 0;
    waitpid(pid, &status, 0);

    alarm(0);
    sigaction(SIGALRM, &old_sa, NULL);

    if (g_timed_out) {
        pam_syslog(pamh, LOG_ERR,
                   "tpm-keyring-unseal helper timed out after %ds, killed",
                   HELPER_TIMEOUT_SECS);
        memset(buf, 0, sizeof(buf));
        return PAM_IGNORE;
    }

    if (total <= 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        pam_syslog(pamh, LOG_NOTICE,
                   "tpm-keyring-unseal helper produced no usable output "
                   "(exit %d) - keyring auto-unlock not available this login",
                   WIFEXITED(status) ? WEXITSTATUS(status) : -1);
        memset(buf, 0, sizeof(buf));
        return PAM_IGNORE;
    }

    buf[total] = '\0';
    if (total > 0 && buf[total - 1] == '\n') {
        buf[total - 1] = '\0';
    }

    int set_rv = pam_set_item(pamh, PAM_AUTHTOK, buf);
    memset(buf, 0, sizeof(buf));

    if (set_rv != PAM_SUCCESS) {
        pam_syslog(pamh, LOG_ERR, "pam_set_item(PAM_AUTHTOK) failed: %s",
                   pam_strerror(pamh, set_rv));
        return PAM_IGNORE;
    }

    pam_syslog(pamh, LOG_INFO,
               "TPM keyring unseal succeeded for user %s, PAM_AUTHTOK set",
               user);

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
