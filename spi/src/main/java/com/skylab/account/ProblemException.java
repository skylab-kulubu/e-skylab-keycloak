package com.skylab.account;

/**
 * Carries a {@link Problem} out of a guard or a helper. Endpoints catch it and return the
 * problem response normally, so Keycloak's error mapper and its transaction rollback never
 * see it: rate-limit counters and brute-force bookkeeping written before the failure commit.
 */
final class ProblemException extends RuntimeException {

    private final transient Problem problem;

    ProblemException(Problem problem) {
        super(problem.code(), null, false, false);
        this.problem = problem;
    }

    Problem problem() {
        return problem;
    }
}
