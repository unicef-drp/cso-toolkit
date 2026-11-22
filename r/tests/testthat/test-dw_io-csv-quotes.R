# dw_use() reads a doubled quote in a quoted CSV field as one quote (#192).
# data.table::fread() keeps `""` as two characters (data.table #1109,
# #4779), so `"say ""hi"""` came back as `say ""hi""`, and each dw_save()
# round trip doubled the quotes again. Python and Stata read it as `say "hi"`;
# the parity case io_edge_values checks the three agree.

write_lines_raw <- function(path, lines) writeBin(charToRaw(paste0(paste(lines, collapse = "\n"), "\n")), path)

test_that("doubled quotes in quoted fields read as single quotes", {
  d <- local_tempdir()
  p <- file.path(d, "q.csv")
  write_lines_raw(p, c("k,a",
                       '1,"say ""hi"""',
                       '2,""""',              # a field holding one quote
                       '3,""',                # empty quoted field
                       '4,"Comma, inside"',
                       "5,plain"))
  x <- dw_use(p, verbose = FALSE)
  expect_identical(x$a, c('say "hi"', '"', "", "Comma, inside", "plain"))
})

test_that("a dw_save() / dw_use() round trip keeps the quotes as they are", {
  d <- local_tempdir()
  p <- file.path(d, "rt.csv")
  val <- c('Quote "inside"', 'two "" quotes', "none")
  x <- data.frame(id = 1:3, a = val, stringsAsFactors = FALSE)
  for (i in 1:3) {                                   # three rounds: no growth
    dw_save(x, path = p, overwrite = TRUE, provenance = FALSE, verbose = FALSE)
    x <- as.data.frame(dw_use(p, verbose = FALSE))
  }
  expect_identical(x$a, val)
})

test_that("tab-separated files are unescaped too; quote = \"\" opts out", {
  d <- local_tempdir()
  p <- file.path(d, "q.tsv")
  write_lines_raw(p, c("k\ta", '1\t"say ""hi"""'))
  expect_identical(dw_use(p, verbose = FALSE)$a, 'say "hi"')
  raw <- csotoolkit:::.read_csv(p, sep = "\t", quote = "")
  expect_identical(raw$a, '"say ""hi"""')            # quoting off: the raw text
})
