# TRUE when an SLC installation can be located (WPSHOME or default roots).
slc_is_installed <- function() {
  wpshome <- Sys.getenv("WPSHOME")
  paths <- if (nzchar(wpshome)) {
    file.path(wpshome, "bin")
  } else {
    slcR:::slc_binary_search_paths()
  }
  any(file.exists(file.path(paths, "wpslinks")))
}
