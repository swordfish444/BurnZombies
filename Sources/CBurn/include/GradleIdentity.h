#ifndef BZ_GRADLE_IDENTITY_H
#define BZ_GRADLE_IDENTITY_H
#include <stdint.h>
typedef struct {
  char distribution[4096];
  char home[4096];
  char version[32];
  int32_t descriptor_count;
} bz_gradle_identity;
/* Projects only Gradle's exact launcher, version and open daemon-log location.
 * No arbitrary arguments, environment, socket endpoints or tokens escape. */
int bz_gradle_launch(int32_t pid, bz_gradle_identity *out);
#endif
