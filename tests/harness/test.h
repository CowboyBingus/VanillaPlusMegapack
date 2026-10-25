/* The pack's minimal test framework: CHECK records a failure and goes on; RUN runs a test case on a fresh fake. */
#ifndef VPM_TEST_H
#define VPM_TEST_H

#include <stdio.h>
#include "fake_hf.h"

extern int test_failures;
extern int test_checks;

#define CHECK(condition) do { test_checks++; if (!(condition)) { test_failures++; \
    printf("  FAILED %s:%d: %s\n", __FILE__, __LINE__, #condition); } } while (0)
#define CHECK_EQ(actual, expected) do { test_checks++; long long a_ = (long long)(actual), e_ = (long long)(expected); \
    if (a_ != e_) { test_failures++; printf("  FAILED %s:%d: %s is %lld, expected %lld\n", __FILE__, __LINE__, #actual, a_, e_); } } while (0)
#define CHECK_LOG(text) do { test_checks++; if (!fake_log_has(text)) { test_failures++; \
    printf("  FAILED %s:%d: the log has no \"%s\"; it was:\n%s", __FILE__, __LINE__, text, fake_log_text()); } } while (0)
#define CHECK_NO_LOG(text) do { test_checks++; if (fake_log_has(text)) { test_failures++; \
    printf("  FAILED %s:%d: the log has \"%s\"\n", __FILE__, __LINE__, text); } } while (0)

#define RUN(test) do { int before_ = test_failures; fake_setup(); test(); \
    printf("%s %s\n", test_failures == before_ ? "ok  " : "FAIL", #test); } while (0)

/* A test file's main ends with this: the summary, and the exit code. */
#define TEST_END() do { printf("%d checks, %d failed\n", test_checks, test_failures); return test_failures != 0; } while (0)
#define TEST_GLOBALS int test_failures; int test_checks

#endif
