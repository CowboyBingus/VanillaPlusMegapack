/* The pack build's identity for the start-up log (diag.c): scripts/build.ps1 passes each as a -D define holding a C
 * string literal (-DVPM_PACK_VERSION="\"0.1.0\"" and the like). A build without them (the tests, an older build script,
 * a hand build) gets these: the manifest's version, no commit, and the compiler's date. */
#ifndef VPM_VERSION_H
#define VPM_VERSION_H

#ifndef VPM_PACK_VERSION
#define VPM_PACK_VERSION "0.1.0"
#endif
#ifndef VPM_COMMIT
#define VPM_COMMIT "unknown"
#endif
#ifndef VPM_BUILD_DATE
#define VPM_BUILD_DATE __DATE__
#endif

#endif
