# paper/

The manuscript, `paper/main.tex`, built from the committed tables and
figures in `output/`. LaTeX build files are git-ignored.

The optional `manuscript` check builds it and checks the page limit:
`Rscript --no-init-file tools/check.R --only manuscript` (set `PAPER_DIR`,
`ROOT_FILE` and `MAX_PAGES` at the top of `tools/check.R`).
