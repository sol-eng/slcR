#' SLC Engine for Quarto
#'
#' @description
#' Provides support for executing SLC code blocks in Quarto documents.
#' This function is automatically called by knitr when processing SLC code chunks.
#'
#' @param options A list of chunk options from knitr, including:
#'   \describe{
#'     \item{code}{Character vector containing the SLC code to execute}
#'     \item{input_data}{Name(s) of R data.frame(s) to make available in SLC. Can be a
#'       single name or comma-separated names (optional)}
#'     \item{output_data}{Name(s) for capturing SLC output data into R. Can be a single
#'       name or comma-separated names (optional)}
#'     \item{new_session}{Whether to start a fresh SLC process for this chunk
#'       (default: FALSE). Set to TRUE for an isolated session.}
#'     \item{show_listing}{Whether to include SAS listing (LST) output below the log
#'       (default: TRUE)}
#'     \item{output_files}{Path(s) to files written by SLC code (e.g. PNG images). Can
#'       be a single path or comma-separated paths (optional). Figures are also
#'       auto-discovered -- use this only when the auto-discovery misses a file.}
#'     \item{fig-cap}{Caption(s) for auto-discovered or output_files figures. A single
#'       string is applied to all figures; a vector/list assigns one caption per figure.}
#'     \item{eval}{Whether to evaluate the code (default: TRUE)}
#'     \item{echo}{Whether to show the code (default: TRUE)}
#'     \item{include}{Whether to include output (default: TRUE)}
#'   }
#'
#' @return A knitr engine output object containing the code and results, followed
#'   by any figure markdown.
#'
#' @details
#' This function handles the execution of SLC code within Quarto documents by:
#' \itemize{
#'   \item Initializing SLC connection if needed
#'   \item Exposing \code{&slcr_gpath} -- a per-chunk temp directory -- as a SAS
#'     macro variable, so user code can write figures to a known location with e.g.
#'     \code{ods html body='...' gpath="&slcr_gpath"}
#'   \item Executing the SLC code
#'   \item Capturing output and logs
#'   \item Auto-discovering figures via two complementary mechanisms:
#'     (1) parsing \code{NOTE: Successfully written image <path>} from the SAS log,
#'     (2) scanning \code{&slcr_gpath} for any new image files
#'   \item Rendering figures inline via proper Quarto/pandoc figure markdown
#'   \item Transferring output data from SLC to R if specified
#' }
#'
#' @section ODS GRAPHICS figure capture:
#' Two auto-discovery mechanisms work together -- no \code{output_files} needed:
#' \enumerate{
#'   \item \strong{Log parsing}: after each chunk the engine scans the SAS log for
#'     \code{NOTE: Successfully written image ...} lines. This captures figures
#'     regardless of where ODS writes them.
#'   \item \strong{slcr_gpath scan}: figures written to \code{&slcr_gpath} (a
#'     per-chunk temp directory) are also collected. This supports the explicit
#'     \code{ods html gpath="&slcr_gpath"} pattern and is useful when the default
#'     ODS destination is not listing-based.
#' }
#'
#' @section Multiple datasets:
#' Multiple datasets can be specified using comma-separated names:
#' \itemize{
#'   \item \code{input_data="df1,df2,df3"} - transfers multiple R data.frames to SLC
#'   \item \code{output_data="result1,result2"} - captures multiple datasets from SLC to R
#'   \item \code{output_files="plot.png,report.png"} - embeds additional output files
#' }
#'
#' @section Global Environment Assignment:
#' When \code{output_data} is specified, this function intentionally assigns
#' the resulting dataset(s) to the global environment using
#' \code{assign(..., envir = knitr::knit_global())}.
#'
#' @importFrom knitr engine_output
#' @export
slc_engine <- function(options) {
  if (!is.list(options)) {
    stop("options must be a list")
  }

  code            <- paste(options$code, collapse = "\n")
  output          <- character(0)
  connection      <- NULL
  discovered_imgs <- character(0)

  # Skip execution if eval is FALSE
  if (isFALSE(options$eval)) {
    return(knitr::engine_output(options, code, output))
  }

  tryCatch(
    {
      # Use shared session by default; new_session=TRUE starts an isolated process
      if (isTRUE(options$new_session)) {
        connection <- Slc$new()
      } else {
        connection <- get_shared_connection()
      }
      work_lib <- connection$get_library("WORK")

      # Handle input data if specified
      input_names <- parse_multiple_names(options$input_data)
      if (length(input_names) > 0) {
        for (input_name in input_names) {
          if (!exists(input_name, envir = knitr::knit_global())) {
            stop("Object '", input_name, "' not found in global environment")
          }
          input_data <- get(input_name, envir = knitr::knit_global())
          if (!is.data.frame(input_data)) {
            stop("input_data '", input_name, "' must refer to a data.frame")
          }
          work_lib$create_dataset_from_dataframe(input_data, name = input_name)
        }
      }

      # Execute the code if present
      if (nchar(code) > 0) {
        # -- Set up per-chunk image directory --
        # &slcr_gpath is exposed as a SAS macro variable so user code can write
        # figures to a known location (e.g. ods html gpath="&slcr_gpath").
        safe_label    <- gsub("[^a-zA-Z0-9_-]", "_", options$label %||% "chunk")
        chunk_img_dir <- file.path(tempdir(), paste0("slcr_imgs_", safe_label))
        dir.create(chunk_img_dir, showWarnings = FALSE, recursive = TRUE)

        # Snapshot the directory BEFORE running user code
        imgs_before_dir <- list_image_files(chunk_img_dir)

        # Expose the path as &slcr_gpath
        slcr_setup <- sprintf("%%let slcr_gpath=%s;",
                              gsub("\\\\", "/", chunk_img_dir))
        connection$submit(slcr_setup)

        # Clear stale listing from any prior chunk before submitting user code
        connection$clear_listing_output()

        result     <- connection$submit(code)
        log_output <- connection$get_log()
        output <- if (is.list(log_output) && "log" %in% names(log_output)) {
          log_output$log
        } else {
          as.character(log_output)
        }

        # Append listing output when non-empty and not suppressed
        show_listing <- !isFALSE(options$show_listing)
        if (show_listing) {
          listing <- as.character(connection$get_listing_output())
          if (nzchar(listing)) {
            output <- paste0(
              output,
              "\n<!-- slc-listing-start -->\n",
              listing,
              "\n<!-- slc-listing-end -->"
            )
          }
        }

        # -- Auto-discover figures via two complementary mechanisms --

        # (1) Parse "NOTE: Successfully written image <path>" from the SAS log.
        #     This captures any figure regardless of which ODS destination wrote it.
        log_imgs <- extract_image_paths_from_log(output)

        # (2) Scan &slcr_gpath for images placed there by user code that used
        #     ods html gpath="&slcr_gpath" or similar.
        imgs_after_dir <- list_image_files(chunk_img_dir)
        dir_imgs       <- setdiff(imgs_after_dir, imgs_before_dir)

        discovered_imgs <- unique(c(log_imgs, dir_imgs))
      }

      # Handle output data if specified
      output_names <- parse_multiple_names(options$output_data)
      if (length(output_names) > 0) {
        for (output_name in output_names) {
          output_df <- work_lib$get_dataset_as_dataframe(output_name)
          # Intentional assignment to global environment for Quarto workflow
          assign(output_name, output_df, envir = knitr::knit_global())
        }
      }
    },
    error = function(e) {
      stop(e$message)
    }
  )

  # Merge auto-discovered images with any user-declared output_files paths.
  declared_paths <- parse_multiple_names(options$output_files)
  all_img_paths  <- unique(c(discovered_imgs, declared_paths))

  text_out <- knitr::engine_output(options, code, output)
  fig_out  <- render_slc_figures(all_img_paths, options)

  c(text_out, fig_out)
}


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

#' Extract image file paths from a SAS log string
#'
#' Scans the log for \code{NOTE: Successfully written image <path>} entries.
#' The path may be on the same line or span multiple indented continuation lines
#' (as SAS wraps long paths).  Only paths for which \code{file.exists()} returns
#' \code{TRUE} are returned.
#'
#' @param log_text Character scalar containing the full SAS log.
#' @return Character vector of existing image file paths (may be length 0).
#' @keywords internal
extract_image_paths_from_log <- function(log_text) {
  if (!nzchar(log_text)) return(character(0))

  lines <- strsplit(log_text, "\n")[[1]]
  paths <- character(0)
  n     <- length(lines)
  i     <- 1L

  while (i <= n) {
    if (grepl("NOTE:.*Successfully written image", lines[i])) {
      # Grab everything after the keyword on the same line
      path_so_far <- trimws(
        sub("^.*NOTE:.*Successfully written image\\s*", "", lines[i])
      )

      # Collect indented continuation lines (SAS wraps long paths)
      j <- i + 1L
      while (j <= n) {
        next_line <- lines[j]
        # A continuation line is indented and does not start a new diagnostic
        is_continuation <- grepl("^\\s+\\S", next_line) &&
          !grepl("^\\s*(NOTE|ERROR|WARNING|FATAL)\\s*:", next_line)
        if (!is_continuation) break
        path_so_far <- paste0(path_so_far, trimws(next_line))
        j <- j + 1L
      }

      full_path <- trimws(path_so_far)
      if (nzchar(full_path) && file.exists(full_path)) {
        paths <- c(paths, full_path)
      }
      i <- j
    } else {
      i <- i + 1L
    }
  }

  paths
}


#' List image files in a directory (png, svg, jpg/jpeg)
#' @keywords internal
list_image_files <- function(dir) {
  list.files(dir, pattern = "\\.(png|svg|jpg|jpeg)$",
             full.names = TRUE, ignore.case = TRUE)
}


#' Render SLC figure files as Quarto/pandoc figure markdown
#'
#' Copies each image into knitr's managed figure directory (so that
#' \code{embed-resources: true} picks them up), then returns a markdown string
#' with one \code{![caption](path)} reference per image.  This string is
#' appended to the chunk output OUTSIDE the verbatim block produced by
#' \code{knitr::engine_output}, allowing pandoc to render real figures rather
#' than literal text.
#'
#' @param paths Character vector of absolute paths to image files.
#' @param options knitr chunk options list.  \code{fig-cap} is used for captions
#'   (single string or character/list vector, one entry per image).
#' @return A character string of figure markdown, or \code{NULL} if \code{paths}
#'   is empty or no files are found.
#' @keywords internal
render_slc_figures <- function(paths, options) {
  if (length(paths) == 0) return(NULL)

  # Filter to files that actually exist; warn about missing declared ones
  exists_flag <- vapply(paths, file.exists, logical(1))
  missing     <- paths[!exists_flag]
  if (length(missing) > 0) {
    warning(
      "slcR: figure file(s) not found and will be skipped:\n  ",
      paste(missing, collapse = "\n  "),
      call. = FALSE
    )
  }
  valid <- paths[exists_flag]
  if (length(valid) == 0) return(NULL)

  # Copy each image into knitr's figure directory so embed-resources can find it
  dests <- character(length(valid))
  for (i in seq_along(valid)) {
    ext  <- tools::file_ext(valid[[i]])
    dest <- knitr::fig_path(ext, options, i)
    dir.create(dirname(dest), showWarnings = FALSE, recursive = TRUE)
    file.copy(valid[[i]], dest, overwrite = TRUE)
    dests[[i]] <- dest
  }

  # Resolve figure captions: single string applied to all, or one per figure
  raw_caps <- options[["fig-cap"]]
  caps <- if (is.null(raw_caps)) {
    rep("", length(dests))
  } else {
    cap_vec <- unlist(raw_caps, use.names = FALSE)
    rep_len(as.character(cap_vec), length(dests))
  }

  # Build one Quarto-compatible image reference per figure.
  # pandoc renders  ![caption](path)  as a proper <figure> element with caption.
  fig_lines <- mapply(
    function(dest, cap) {
      if (nzchar(trimws(cap))) {
        sprintf("![%s](%s)", cap, dest)
      } else {
        sprintf("![](%s)", dest)
      }
    },
    dests, caps,
    USE.NAMES = FALSE
  )

  # Blank line between figures so pandoc treats each as an independent block
  paste(fig_lines, collapse = "\n\n")
}


#' Parse comma-separated names from chunk options
#'
#' @param names_string A string containing comma-separated names, or NULL
#' @return A character vector of trimmed names, or character(0) if input is NULL/empty
#' @keywords internal
parse_multiple_names <- function(names_string) {
  if (is.null(names_string) || names_string == "") {
    return(character(0))
  }
  trimws(strsplit(names_string, ",")[[1]])
}


#' Embed output files written by SLC code as inline knitr figure markup
#'
#' @description
#' Deprecated. Figures are now handled automatically via log parsing and
#' \code{render_slc_figures()}.  This function is retained for backward
#' compatibility only.
#'
#' @param options knitr chunk options list; uses \code{output_files} field
#' @return Character string of figure markdown, or \code{NULL}
#' @keywords internal
embed_output_files <- function(options) {
  paths <- parse_multiple_names(options$output_files)
  render_slc_figures(paths, options)
}


#' Null-coalescing operator (internal)
#' @keywords internal
`%||%` <- function(x, y) if (is.null(x)) y else x
