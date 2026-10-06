#' Altair SLC Connection Interface
#'
#' @description
#' The `Slc` class provides the main interface for connecting to and interacting
#' with Altair SLC (Statistical Language Compiler). It manages the SLC process,
#' handles communication via the ORB protocol, and provides high-level methods
#' for submitting SAS code and managing data.
#'
#' @details
#' This class handles:
#' \itemize{
#'   \item Starting and managing the SLC process (`wpslinks`)
#'   \item Establishing communication via named pipes
#'   \item Creating and managing SLC sessions
#'   \item Submitting SAS code for execution
#'   \item Accessing logs, listings, and macro variables
#'   \item Managing SAS libraries and datasets
#' }
#'
#' The connection uses the ORB (Object Request Broker) protocol to communicate
#' with SLC through named pipes (FIFOs on Unix/Linux systems).
#'
#' @section Environment Requirements:
#' The SLC binary must be available. The class looks for it in:
#' \enumerate{
#'   \item `$WPSHOME/bin/wpslinks` (if WPSHOME environment variable is set)
#'   \item `$WPSHOME/MacOS/wpslinks` (on macOS)
#'   \item Default installation paths like `/opt/altair/slc/*/bin`
#' }
#'
#' Set the WPSHOME environment variable if SLC is installed in a non-standard location:
#' \code{Sys.setenv(WPSHOME = "/path/to/slc/installation")}
#'
#' @examples
#' \dontrun{
#' # Basic connection and code submission
#' slc <- Slc$new()
#'
#' # Submit SAS code
#' slc$submit('
#'   data test;
#'     x = 1;
#'     y = 2;
#'   run;
#' ')
#'
#' # Get the log
#' log_output <- slc$get_log()
#' cat(log_output)
#'
#' # Get listing output (from PROC PRINT, etc.)
#' slc$submit('proc print data=test; run;')
#' listing <- slc$get_listing_output()
#'
#' # Work with libraries and datasets
#' work_lib <- slc$get_library("WORK")
#' datasets <- work_lib$get_dataset_names()
#'
#' # Convert between R and SAS data
#' work_lib$create_dataset_from_dataframe(mtcars, "cars")
#' cars_df <- work_lib$get_dataset_as_dataframe("cars")
#'
#' # Macro variables
#' slc$submit('%let myvar = hello world;')
#' value <- slc$get_macro_variable("myvar")
#'
#' # Clean shutdown
#' slc$shutdown()
#' }
#'
#' @export
Slc <- R6::R6Class(
  "Slc",
  private = list(
    orb_instance = NULL,
    server_obj = NULL,
    session_obj = NULL,
    process_handle = NULL,
    pipe_dir = NULL,

    start_slc_process = function(sys_options) {
      # Find SLC binary
      bin_dir <- self$find_slc_binary()
      if (is.null(bin_dir)) {
        stop("Could not find SLC binary")
      }

      slc_binary <- file.path(bin_dir, "wpslinks")
      if (!file.exists(slc_binary)) {
        stop(sprintf("SLC binary not found at %s", slc_binary))
      }

      # Build command line arguments - use -namedpipe flag
      # This tells SLC to create its own pipes and report their names
      # System options are not passed here: wpslinks rejects them on its
      # command line, so they go to the session as it initialises instead.
      args <- c("-namedpipe")

      # Start process with stdout piped so we can read pipe names
      private$process_handle <- processx::process$new(
        slc_binary,
        args,
        stdout = "|",
        stderr = "|"
      )

      # Read pipe names from stdout
      # SLC will output lines like:
      # "Reading from pipe /tmp/..."
      # "Writing to pipe /tmp/..."
      outpipe_name <- NULL
      inpipe_name <- NULL

      max_attempts <- 100
      attempt <- 0

      while (
        (is.null(outpipe_name) || is.null(inpipe_name)) &&
          attempt < max_attempts
      ) {
        # Check if process is still alive
        if (!private$process_handle$is_alive()) {
          stderr_output <- private$process_handle$read_error()
          stop(sprintf(
            "SLC process died during startup. stderr: %s",
            stderr_output
          ))
        }

        # Try to read a line (non-blocking)
        line <- private$process_handle$read_output_lines(n = 1)

        if (length(line) > 0 && nchar(line[1]) > 0) {
          if (grepl("^Reading from pipe ", line[1])) {
            outpipe_name <- sub("^Reading from pipe ", "", line[1])
            outpipe_name <- trimws(outpipe_name)
          } else if (grepl("^Writing to pipe ", line[1])) {
            inpipe_name <- sub("^Writing to pipe ", "", line[1])
            inpipe_name <- trimws(inpipe_name)
          }
        } else {
          # No output yet, wait a bit
          Sys.sleep(0.01)
        }

        attempt <- attempt + 1
      }

      if (is.null(outpipe_name) || is.null(inpipe_name)) {
        stop("Failed to read pipe names from SLC process")
      }

      # Now connect to the pipes that SLC created
      # Note: inpipe_name is what SLC writes to (our input)
      #       outpipe_name is what SLC reads from (our output)
      conn <- NamedPipeConnection$new(inpipe_name, outpipe_name)

      # Create ORB with process handle for liveness checking
      private$orb_instance <- Orb$new(conn, private$process_handle)

      # Get server object
      private$server_obj <- WpsServer$new(private$orb_instance, "wpsserver")

      # Create session
      private$session_obj <- private$server_obj$create_session()

      # Initialize session with options if provided
      if (length(sys_options) > 0) {
        private$session_obj$init_with_options(sys_options)
      } else {
        private$session_obj$init()
      }
    },

    # Finalizer
    finalize = function() {
      self$shutdown()
    }
  ),

  public = list(
    #' @description Create new SLC connection
    #' @param sys_options List of system options
    initialize = function(sys_options = list()) {
      private$start_slc_process(sys_options)
    },

    #' @description Find SLC binary directory
    #' @return Path to binary directory or NULL
    find_slc_binary = function() {
      if (Sys.getenv("WPSHOME") != "") {
        bindir <- file.path(
          Sys.getenv("WPSHOME"),
          self$get_binary_folder_name()
        )
        if (dir.exists(bindir)) {
          return(bindir)
        } else {
          stop("WPSHOME does not point to a valid Altair SLC installation")
        }
      }

      search_paths <- self$get_binary_search_paths()
      for (path in search_paths) {
        if (dir.exists(path)) {
          return(path)
        }
      }

      return(NULL)
    },

    #' @description Get binary folder name based on OS
    #' @return Folder name string
    get_binary_folder_name = function() {
      if (.Platform$OS.type == "windows") {
        return("bin")
      } else {
        return("bin")
      }
    },

    #' @description Get binary search paths
    #' @return Character vector of paths
    get_binary_search_paths = function() {
      c(
        "/opt/altair/slc/2026/bin",
        "/opt/wps/bin",
        "C:/Program Files/Altair/SLC/2026/bin"
      )
    },

    #' @description Get binary name
    #' @return Binary name string
    get_binary_name = function() {
      if (.Platform$OS.type == "windows") {
        return("wpslinks.exe")
      } else {
        return("wpslinks")
      }
    },

    #' @description Submit SAS code
    #' @param text SAS code string
    #' @return Integer return code
    submit = function(text) {
      private$session_obj$submit(text)
    },

    #' @description Submit SAS code from file
    #' @param filename Path to file
    #' @return Integer return code
    submit_file = function(filename) {
      code <- paste(readLines(filename), collapse = "\n")
      self$submit(code)
    },

    #' @description Get library reference
    #' @param name Library name (default "WORK")
    #' @return Library object
    get_library = function(name = "WORK") {
      libref <- private$session_obj$get_libref(name)
      Library$new(libref, private$session_obj)
    },

    #' @description Create new library
    #' @param name Library name
    #' @param path Library path
    #' @param engine Engine name (default "WPD")
    #' @return Library object
    create_library = function(name, path, engine = "WPD") {
      libref <- private$session_obj$assign_libref(name, path, engine)
      Library$new(libref, private$session_obj)
    },

    #' @description Get library names
    #' @return Character vector of library names
    get_library_names = function() {
      # Submit code to get library names
      self$submit(
        "proc sql noprint; select distinct libname into :libs separated by '|' from dictionary.libnames; quit;"
      )
      libs_str <- self$get_macro_variable("libs")
      if (libs_str == "") {
        return(character(0))
      }
      strsplit(libs_str, "|", fixed = TRUE)[[1]]
    },

    #' @description Get macro variable value
    #' @param name Variable name
    #' @return String value
    get_macro_variable = function(name) {
      private$session_obj$get_macro_variable(name)
    },

    #' @description Set macro variable
    #' @param name Variable name
    #' @param value Variable value
    set_macro_variable = function(name, value) {
      private$session_obj$set_macro_variable(name, value)
      invisible(self)
    },

    #' @description Get log output
    #' @return String
    get_log = function() {
      log_file <- private$session_obj$get_log_file()
      log_file$get_contents()
    },

    #' @description Get listing output
    #' @return String
    get_listing_output = function() {
      listing_file <- private$session_obj$get_listing_file()
      listing_file$get_contents()
    },

    #' @description Clear listing output
    clear_listing_output = function() {
      private$session_obj$clear_listing_file()
      invisible(self)
    },

    #' @description Shutdown SLC connection
    shutdown = function() {
      if (!is.null(private$orb_instance)) {
        tryCatch(
          {
            private$server_obj$shutdown_server()
            private$orb_instance$shutdown()
          },
          error = function(e) {
            message("Error during shutdown: ", e$message)
          }
        )
      }

      if (
        !is.null(private$process_handle) && private$process_handle$is_alive()
      ) {
        private$process_handle$kill()
      }

      invisible(self)
    }
  )
)
