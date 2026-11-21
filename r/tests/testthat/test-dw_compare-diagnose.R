# dw_compare(diagnose = TRUE) / dw_diff_profile() and the same-file guard
# (#111). Mirror: python/tests/test_dw_compare_diagnose.py.

REF <- data.frame(
	REF_AREA = c("AAA", "BBB", "CCC", "DDD", "EEE", "R1"),
	TIME_PERIOD = c(2020, 2020, 2020, 2020, 2020, 2020),
	OBS_VALUE = c(10, 20, 30, 40, 50, 100),
	POP = c(1, 2, 3, 4, 5, 6),
	stringsAsFactors = FALSE)
CUR <- data.frame(
	REF_AREA = c("AAA", "BBB", "CCC", "DDD", "R1", "FFF"),        # EEE removed, FFF added
	TIME_PERIOD = c(2020, 2020, 2020, 2020, 2020, 2020),
	OBS_VALUE = c(10, 22, 33, 40, 110, 60),                      # BBB +10%, CCC +10%, R1 +10%
	POP = c(1, 2, 3, 9, 6, 7),                                   # DDD's POP differs
	stringsAsFactors = FALSE)
KEYS <- c("REF_AREA", "TIME_PERIOD")

test_that("diagnose = TRUE profiles the columns, the drift and the keys", {
	r <- dw_compare(CUR, REF, by = KEYS, numeric_value_cols = c("OBS_VALUE", "POP"),
	                diagnose = TRUE, verbose = FALSE)
	p <- r$profile
	expect_identical(p$columns$column, c("OBS_VALUE", "POP"))
	expect_identical(p$columns$n_changed, c(3L, 1L))
	ob <- p$magnitude[p$magnitude$column == "OBS_VALUE", ]
	expect_equal(ob$rel_q50, 0.1)                                # every change is +10%
	expect_equal(ob$abs_max, 10)
	expect_identical(sort(p$keys$value[p$keys$key == "REF_AREA"]), c("BBB", "CCC", "DDD", "R1"))
	expect_identical(p$added$value[p$added$key == "REF_AREA"], "FFF")
	expect_identical(p$removed$value[p$removed$key == "REF_AREA"], "EEE")
	expect_true(any(grepl("^  diff columns: OBS_VALUE\\(3\\) POP\\(1\\)$", p$text)))
	expect_true(any(grepl("rel: 0.1 / 0.1 / 0.1 / 0.1", p$text, fixed = TRUE)))
})

test_that("without diagnose the result keeps its four elements", {
	r <- dw_compare(CUR, REF, by = KEYS, verbose = FALSE)
	expect_identical(names(r), c("summary", "added", "removed", "changed"))
})

test_that("no difference: an empty profile", {
	r <- dw_compare(REF, REF, by = KEYS, numeric_value_cols = "OBS_VALUE",
	                diagnose = TRUE, verbose = FALSE)
	expect_identical(nrow(r$profile$columns), 0L)
	expect_identical(r$profile$text, character(0))
})

test_that("write_report_to with diagnose writes the profile", {
	d <- local_tempdir()
	dw_compare(CUR, REF, by = KEYS, numeric_value_cols = "OBS_VALUE", diagnose = TRUE,
	           label = "t", write_report_to = d, verbose = FALSE)
	expect_true(file.exists(file.path(d, "t_profile.txt")))
	expect_match(readLines(file.path(d, "t_profile.txt"))[1], "diff columns")
})

test_that("reviewer mode: a sandbox path remapped to the canonical file stops", {
	sandbox <- local_tempdir()
	canon <- local_tempdir()
	local_state(dw_mode = "reviewer", teamsWrkData = sandbox, teamsWrkDataCanonical = canon)
	utils::write.csv(CUR, file.path(sandbox, "x.csv"), row.names = FALSE)
	utils::write.csv(REF, file.path(canon, "x.csv"), row.names = FALSE)
	err <- tryCatch(dw_compare(file.path(sandbox, "x.csv"), file.path(canon, "x.csv"),
	                           by = KEYS, verbose = FALSE), error = identity)
	expect_envelope(err, "dw_compare")
	expect_match(conditionMessage(err), "resolve to the same file")
	expect_match(conditionMessage(err), "reviewer mode")
	# The fix the message gives: pass the new data in memory.
	r <- dw_compare(data.table::fread(file.path(sandbox, "x.csv")), file.path(canon, "x.csv"),
	                by = KEYS, verbose = FALSE)
	expect_gt(r$summary$changed, 0)
})

test_that("the same path twice stops; two files compare as before", {
	d <- local_tempdir()
	p1 <- file.path(d, "a.csv"); p2 <- file.path(d, "b.csv")
	utils::write.csv(REF, p1, row.names = FALSE)
	utils::write.csv(CUR, p2, row.names = FALSE)
	expect_error(dw_compare(p1, p1, by = KEYS, verbose = FALSE), "resolve to the same file")
	expect_identical(dw_compare(p2, p1, by = KEYS, verbose = FALSE)$summary$added, 1L)
})
