# R/zzz.R
.slcr_env <- new.env(parent = emptyenv())

.onLoad <- function(libname, pkgname) {
  # Register SLC engine
  knitr::knit_engines$set(slc = slc_engine)
}

.onAttach <- function(libname, pkgname) {
  # Setup Quarto integration when package is attached
  if (interactive() && is_quarto_context()) {
    setup_slc_quarto()
  }
}
