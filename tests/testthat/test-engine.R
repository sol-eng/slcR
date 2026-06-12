# Tests for the slcR knitr engine (engine.R)
# Pure-R unit tests run everywhere; SLC integration tests are skipped when
# the SLC binary is absent.

slc_available <- file.exists("/opt/altair/slc/2026/bin/wpslinks")

# ---------------------------------------------------------------------------
# extract_image_paths_from_log() unit tests
# ---------------------------------------------------------------------------

test_that("extract_image_paths_from_log handles empty / blank input", {
  expect_equal(slcR:::extract_image_paths_from_log(""), character(0))
  expect_equal(slcR:::extract_image_paths_from_log("no images here"), character(0))
})

test_that("extract_image_paths_from_log finds a path on the same line", {
  # Create a real temp file so file.exists() returns TRUE
  tmp <- tempfile(fileext = ".png")
  file.create(tmp)
  on.exit(unlink(tmp))

  log <- paste0(
    "NOTE: Data set created\n",
    "NOTE: Successfully written image ", tmp, "\n",
    "NOTE: Procedure step took : real time : 0.1\n"
  )
  result <- slcR:::extract_image_paths_from_log(log)
  expect_equal(result, tmp)
})

test_that("extract_image_paths_from_log finds a path split over continuation lines", {
  # SAS wraps long paths with leading whitespace on continuation lines
  tmp <- tempfile(fileext = ".png")
  file.create(tmp)
  on.exit(unlink(tmp))

  # Split the path into two pieces to simulate SAS log wrapping
  dir_part  <- dirname(tmp)
  file_part <- basename(tmp)

  log <- paste0(
    "NOTE: Successfully written image\n",
    "      ", dir_part, "/\n",
    "      ", file_part, "\n",
    "NOTE: Procedure step took : real time : 0.05\n"
  )
  result <- slcR:::extract_image_paths_from_log(log)
  expect_equal(normalizePath(result), normalizePath(tmp))
})

test_that("extract_image_paths_from_log returns empty for non-existent paths", {
  log <- "NOTE: Successfully written image /no/such/file.png\n"
  expect_equal(slcR:::extract_image_paths_from_log(log), character(0))
})

test_that("extract_image_paths_from_log finds multiple images", {
  tmp1 <- tempfile(fileext = ".png"); file.create(tmp1)
  tmp2 <- tempfile(fileext = ".png"); file.create(tmp2)
  on.exit({ unlink(tmp1); unlink(tmp2) })

  log <- paste0(
    "NOTE: Successfully written image ", tmp1, "\n",
    "NOTE: Other stuff\n",
    "NOTE: Successfully written image ", tmp2, "\n"
  )
  result <- slcR:::extract_image_paths_from_log(log)
  expect_setequal(result, c(tmp1, tmp2))
})

# ---------------------------------------------------------------------------
# list_image_files() unit tests
# ---------------------------------------------------------------------------

test_that("list_image_files returns PNG/SVG/JPG files only", {
  d <- tempfile(); dir.create(d)
  on.exit(unlink(d, recursive = TRUE))

  file.create(file.path(d, "plot.png"))
  file.create(file.path(d, "chart.SVG"))
  file.create(file.path(d, "photo.JPEG"))
  file.create(file.path(d, "data.csv"))
  file.create(file.path(d, "notes.txt"))

  result <- slcR:::list_image_files(d)
  expect_length(result, 3L)
})

test_that("list_image_files returns empty vector for empty directory", {
  d <- tempfile(); dir.create(d)
  on.exit(unlink(d, recursive = TRUE))
  expect_length(slcR:::list_image_files(d), 0L)
})

# ---------------------------------------------------------------------------
# parse_multiple_names() unit tests
# ---------------------------------------------------------------------------

test_that("parse_multiple_names splits comma-separated strings", {
  expect_equal(slcR:::parse_multiple_names("a,b,c"), c("a", "b", "c"))
})

test_that("parse_multiple_names trims whitespace", {
  expect_equal(slcR:::parse_multiple_names("a , b , c"), c("a", "b", "c"))
})

test_that("parse_multiple_names returns character(0) for NULL", {
  expect_equal(slcR:::parse_multiple_names(NULL), character(0))
})

test_that("parse_multiple_names returns character(0) for empty string", {
  expect_equal(slcR:::parse_multiple_names(""), character(0))
})

# ---------------------------------------------------------------------------
# render_slc_figures() unit tests
# ---------------------------------------------------------------------------

test_that("render_slc_figures returns NULL for empty paths", {
  opts <- list(label = "test", `fig-cap` = NULL)
  expect_null(slcR:::render_slc_figures(character(0), opts))
})

test_that("render_slc_figures warns and returns NULL when file is missing", {
  opts <- list(label = "test", `fig-cap` = NULL)
  expect_warning(
    result <- slcR:::render_slc_figures("/nonexistent/path/fig.png", opts),
    "not found"
  )
  expect_null(result)
})

test_that("render_slc_figures copies file to knitr fig dir and returns markdown", {
  src_dir <- tempfile(); dir.create(src_dir)
  on.exit(unlink(src_dir, recursive = TRUE))

  src <- file.path(src_dir, "myplot.png")
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), src)

  opts <- knitr::opts_chunk$merge(list(label = "test-chunk", `fig-cap` = NULL))
  result <- slcR:::render_slc_figures(src, opts)

  expect_type(result, "character")
  expect_match(result, "^!\\[\\]\\(")
  expect_match(result, "\\.png\\)$")
})

test_that("render_slc_figures applies caption correctly", {
  src_dir <- tempfile(); dir.create(src_dir)
  on.exit(unlink(src_dir, recursive = TRUE))

  src <- file.path(src_dir, "fig.png")
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), src)

  opts <- knitr::opts_chunk$merge(list(label = "test-cap", `fig-cap` = "My caption"))
  result <- slcR:::render_slc_figures(src, opts)
  expect_match(result, "!\\[My caption\\]")
})

test_that("render_slc_figures assigns one caption per figure when given a list", {
  src_dir <- tempfile(); dir.create(src_dir)
  on.exit(unlink(src_dir, recursive = TRUE))

  src1 <- file.path(src_dir, "fig1.png"); writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), src1)
  src2 <- file.path(src_dir, "fig2.png"); writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), src2)

  opts <- knitr::opts_chunk$merge(list(
    label     = "test-caps",
    `fig-cap` = list("Caption one", "Caption two")
  ))
  result <- slcR:::render_slc_figures(c(src1, src2), opts)
  expect_match(result, "Caption one")
  expect_match(result, "Caption two")
})

test_that("render_slc_figures separates multiple figures with blank lines", {
  src_dir <- tempfile(); dir.create(src_dir)
  on.exit(unlink(src_dir, recursive = TRUE))

  src1 <- file.path(src_dir, "a.png"); writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), src1)
  src2 <- file.path(src_dir, "b.png"); writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), src2)

  opts <- knitr::opts_chunk$merge(list(label = "two-figs", `fig-cap` = NULL))
  result <- slcR:::render_slc_figures(c(src1, src2), opts)
  expect_match(result, "!\\[\\].*\n\n!\\[\\]", perl = TRUE)
})

# ---------------------------------------------------------------------------
# embed_output_files() backward-compatibility shim
# ---------------------------------------------------------------------------

test_that("embed_output_files still works as a backward-compat wrapper", {
  src_dir <- tempfile(); dir.create(src_dir)
  on.exit(unlink(src_dir, recursive = TRUE))

  src <- file.path(src_dir, "compat.png")
  writeBin(as.raw(c(0x89, 0x50, 0x4e, 0x47)), src)

  opts <- knitr::opts_chunk$merge(list(
    label        = "compat-test",
    output_files = src,
    `fig-cap`    = NULL
  ))
  result <- slcR:::embed_output_files(opts)
  expect_type(result, "character")
  expect_match(result, "\\.png\\)")
})

# ---------------------------------------------------------------------------
# SLC integration tests -- require the binary to be present
# ---------------------------------------------------------------------------

test_that("&slcr_gpath macro variable is set to a writable temp directory", {
  skip_if_not(slc_available, "SLC not installed")

  slc <- Slc$new()
  on.exit(slc$shutdown())

  img_dir <- file.path(tempdir(), "slcr_test_gpath")
  dir.create(img_dir, showWarnings = FALSE, recursive = TRUE)

  slc$submit(sprintf("%%let slcr_gpath=%s;", gsub("\\\\", "/", img_dir)))
  val <- slc$get_macro_variable("slcr_gpath")

  expect_equal(normalizePath(val, mustWork = FALSE),
               normalizePath(img_dir, mustWork = FALSE))
})

test_that("extract_image_paths_from_log finds image from a real SAS chart", {
  skip_if_not(slc_available, "SLC not installed")

  slc <- Slc$new()
  on.exit(slc$shutdown())

  slc$submit("
    data work.pts;
      do x = 1 to 5; y = x * 2; output; end;
    run;
    proc sgplot data=work.pts;
      scatter x=x y=y;
    run;
  ")

  log     <- slc$get_log()
  img_paths <- slcR:::extract_image_paths_from_log(log)

  expect_gte(length(img_paths), 1L)
  expect_true(all(file.exists(img_paths)))
})

test_that("slc_engine auto-discovers figures via log parsing, no output_files needed", {
  skip_if_not(slc_available, "SLC not installed")

  slcR:::shutdown_shared_connection()
  on.exit(slcR:::shutdown_shared_connection())

  opts <- knitr::opts_chunk$merge(list(
    engine       = "slc",
    label        = "auto-fig-test",
    echo         = FALSE,
    eval         = TRUE,
    output_files = NULL,
    `fig-cap`    = "Auto-discovered figure",
    show_listing = FALSE,
    code = c(
      "data work.pts;",
      "  do x = 1 to 5; y = x**2; output; end;",
      "run;",
      "proc sgplot data=work.pts;",
      "  series x=x y=y;",
      "run;"
    )
  ))

  result   <- slc_engine(opts)
  combined <- paste(result, collapse = "")

  # Engine output should include figure markdown
  expect_match(combined, "!\\[.*\\]\\(.*\\.png\\)", perl = TRUE)
})

test_that("slc_engine does not add figures when chunk produces no chart", {
  skip_if_not(slc_available, "SLC not installed")

  slcR:::shutdown_shared_connection()
  on.exit(slcR:::shutdown_shared_connection())

  opts <- knitr::opts_chunk$merge(list(
    engine       = "slc",
    label        = "no-fig-test",
    echo         = FALSE,
    eval         = TRUE,
    output_files = NULL,
    show_listing = FALSE,
    code = c("data work.d2; a = 99; run;")
  ))

  result   <- slc_engine(opts)
  combined <- paste(result, collapse = "")

  expect_no_match(combined, "!\\[", perl = TRUE)
})
