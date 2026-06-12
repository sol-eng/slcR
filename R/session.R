#' Get or create the shared SLC connection for this document render
#'
#' Returns the cached connection stored in `.slcr_env`. Creates a new one on
#' first call and registers a knitr `document` hook to shut it down when the
#' document finishes rendering.
#'
#' @return An \code{Slc} object
#' @keywords internal
get_shared_connection <- function() {
  conn <- .slcr_env$connection

  # Reuse if alive
  if (!is.null(conn)) {
    ph <- conn$.__enclos_env__$private$process_handle
    if (!is.null(ph) && ph$is_alive()) {
      return(conn)
    }
  }

  # Create a fresh connection and cache it
  conn <- Slc$new()
  .slcr_env$connection <- conn

  # Register cleanup hook once (compose with any existing document hook)
  old_hook <- knitr::knit_hooks$get("document")
  knitr::knit_hooks$set(document = function(x) {
    shutdown_shared_connection()
    if (is.function(old_hook)) old_hook(x) else x
  })

  conn
}


#' Shut down and remove the cached shared SLC connection
#'
#' Safe to call even when no connection is cached.
#'
#' @keywords internal
shutdown_shared_connection <- function() {
  if (exists("connection", envir = .slcr_env, inherits = FALSE)) {
    conn <- .slcr_env$connection
    tryCatch(conn$shutdown(), error = function(e) NULL)
    rm("connection", envir = .slcr_env)
  }
  # Clear cached WORK path so it's re-queried for the next render
  if (exists("slc_work_path", envir = .slcr_env, inherits = FALSE)) {
    rm("slc_work_path", envir = .slcr_env)
  }
  invisible(NULL)
}
