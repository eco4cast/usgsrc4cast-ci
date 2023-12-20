
# wrapper file for running forecast pipeline; called from gitlab CI

library(targets)
tar_make()
tar_meta(fields = error, complete_only = TRUE)

