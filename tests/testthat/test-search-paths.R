test_that("slc_binary_search_paths orders versions newest first", {
  root <- tempfile("slcroot")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  for (v in c("2025", "2027", "2026", "2026.1", "notaversion")) {
    dir.create(file.path(root, v))
  }

  paths <- slcR:::slc_binary_search_paths(roots = root)

  expect_equal(
    paths,
    c(
      file.path(root, c("2027", "2026.1", "2026", "2025"), "bin"),
      "/opt/wps/bin"
    )
  )
})

test_that("slc_binary_search_paths skips missing or empty roots", {
  root <- tempfile("slcroot")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  paths <- slcR:::slc_binary_search_paths(
    roots = c(file.path(root, "missing"), root)
  )
  expect_equal(paths, "/opt/wps/bin")
})
