test_that("Slc class can be instantiated", {
  # Skip if SLC is not installed
  skip_if_not(file.exists("/opt/altair/slc/2026/bin/wpslinks"),
              "SLC not installed")

  slc <- Slc$new()
  expect_s3_class(slc, "Slc")
  slc$shutdown()
})

test_that("Binary path detection works", {
  # Skip if SLC is not installed
  skip_if_not(file.exists("/opt/altair/slc/2026/bin/wpslinks"),
              "SLC not installed")

  slc <- Slc$new()

  # Test binary folder name detection (returns "bin" not "/bin")
  if (Sys.info()["sysname"] == "Darwin") {
    expect_equal(slc$get_binary_folder_name(), "MacOS")
  } else {
    expect_equal(slc$get_binary_folder_name(), "bin")
  }

  # Test binary name detection
  if (Sys.info()["sysname"] == "Windows") {
    expect_equal(slc$get_binary_name(), "wpslinks.exe")
  } else {
    expect_equal(slc$get_binary_name(), "wpslinks")
  }

  slc$shutdown()
})
test_that("System options are applied to the session", {
  skip_if_not(file.exists("/opt/altair/slc/2026/bin/wpslinks"),
              "SLC not installed")

  slc <- Slc$new(list(XCMD = "NO"))
  on.exit(slc$shutdown())

  slc$submit("%put XCMD is %sysfunc(getoption(XCMD));")
  expect_match(slc$get_log(), "XCMD is NOXCMD", fixed = TRUE)
})
