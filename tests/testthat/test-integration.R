test_that("Slc connection can submit and execute code", {
  skip_if_not(slc_is_installed(),
              "SLC not installed")

  slc <- Slc$new()

  # Submit simple data step
  result <- slc$submit('data test; x = 1; y = 2; run;')

  # Result should be 0 (success)
  expect_equal(result, 0L)

  # Log should contain success messages
  log <- slc$get_log()
  expect_match(log, "Data set")

  slc$shutdown()
})

test_that("Slc can get and set macro variables", {
  skip_if_not(slc_is_installed(),
              "SLC not installed")

  slc <- Slc$new()

  # Set macro variable
  slc$set_macro_variable("testvar", "hello world")

  # Get it back
  value <- slc$get_macro_variable("testvar")
  expect_equal(value, "hello world")

  slc$shutdown()
})

test_that("Slc can work with libraries", {
  skip_if_not(slc_is_installed(),
              "SLC not installed")

  slc <- Slc$new()

  # Create a dataset
  slc$submit('data work.test; x = 1; y = 2; run;')

  # Get WORK library
  work_lib <- slc$get_library("WORK")
  expect_s3_class(work_lib, "Library")

  # List datasets
  datasets <- work_lib$get_dataset_names()
  expect_true("TEST" %in% datasets)

  slc$shutdown()
})

test_that("Slc can get listing output", {
  skip_if_not(slc_is_installed(),
              "SLC not installed")

  slc <- Slc$new()

  # Create a dataset and print it
  slc$submit('data work.test; x = 1; y = 2; run;')
  slc$submit('proc print data=work.test; run;')

  # Get listing output
  listing <- slc$get_listing_output()
  expect_match(listing, "x")
  expect_match(listing, "y")

  slc$shutdown()
})

test_that("Slc handles errors gracefully", {
  skip_if_not(slc_is_installed(),
              "SLC not installed")

  slc <- Slc$new()

  # Submit invalid code
  result <- slc$submit('data test; invalid syntax here')

  # Should still return (error handling in log, not exception)
  expect_type(result, "integer")

  # Log should contain error messages
  log <- slc$get_log()
  expect_match(log, "ERROR")

  slc$shutdown()
})

test_that("Multiple Slc connections can coexist", {
  skip_if_not(slc_is_installed(),
              "SLC not installed")

  slc1 <- Slc$new()
  slc2 <- Slc$new()

  # Each should work independently
  slc1$set_macro_variable("var1", "value1")
  slc2$set_macro_variable("var2", "value2")

  expect_equal(slc1$get_macro_variable("var1"), "value1")
  expect_equal(slc2$get_macro_variable("var2"), "value2")

  slc1$shutdown()
  slc2$shutdown()
})

test_that("Slc can submit code from file", {
  skip_if_not(slc_is_installed(),
              "SLC not installed")

  slc <- Slc$new()

  # Create a temporary SAS file
  temp_file <- tempfile(fileext = ".sas")
  writeLines(c(
    "data test;",
    "  x = 100;",
    "  y = 200;",
    "run;"
  ), temp_file)

  # Submit the file
  result <- slc$submit_file(temp_file)
  expect_equal(result, 0L)

  # Check it worked
  log <- slc$get_log()
  expect_match(log, "Data set")

  # Clean up
  unlink(temp_file)
  slc$shutdown()
})
