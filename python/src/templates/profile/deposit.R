#----------------------------------------
# 6. Deposit paths (The CSO Handbook, "Wiring the contract")
#----------------------------------------
# The canonical deposit is Teams 060.DW-MASTER under your teamsRoot. A
# producer reads and writes it; a reviewer writes only to sandboxRoot, a
# folder outside the repository and outside OneDrive, and reads the
# deposit through the *Canonical aliases. dw_save(), dw_use() and
# dw_api_fetch() route by these globals.
deposit_hint <- sprintf(paste0(
  "    In %s, inside your user block:\n",
  "      %s:\n",
  "        teamsRoot: \"C:/Users/%s/UNICEF/<library>\"   # the folder that contains 060.DW-MASTER\n",
  "        sandboxRoot: \"C:/Users/%s/dw-repro\"         # reviewer writes; outside the repo and OneDrive\n",
  "    (template: _config_template/user_config.yml)."),
  config_path, USERNAME, USERNAME, USERNAME)
teamsRoot <- user_setting("teamsRoot")
if (!(is.character(teamsRoot) && length(teamsRoot) == 1 && nzchar(teamsRoot))) {
  stop("[X] profile: no teamsRoot for ", USERNAME, ".\n", deposit_hint, call. = FALSE)
}
teamsFolderCanonical  <- file.path(teamsRoot, "060.DW-MASTER")
teamsRawDataCanonical <- file.path(teamsFolderCanonical, "01_dw_prep", "011_rawdata")
teamsWrkDataCanonical <- file.path(teamsFolderCanonical, "01_dw_prep", "013_wrkdata")
if (!dir.exists(teamsFolderCanonical)) {
  message("[!] profile: the deposit ", teamsFolderCanonical, " is not here (Teams not synced?). ",
          "Reads from it will fail; nothing is written there unless you are a producer.")
}
if (identical(dw_mode, "producer")) {
  teamsFolder  <- teamsFolderCanonical
  teamsRawData <- teamsRawDataCanonical
  teamsWrkData <- teamsWrkDataCanonical
  message("[!] PRODUCER mode: writes go to the canonical deposit, ", teamsFolder)
} else {
  sandboxRoot <- user_setting("sandboxRoot")
  if (!(is.character(sandboxRoot) && length(sandboxRoot) == 1 && nzchar(sandboxRoot))) {
    stop("[X] profile: reviewer mode needs a sandboxRoot for ", USERNAME, ".\n",
         deposit_hint, call. = FALSE)
  }
  teamsFolder  <- sandboxRoot
  teamsRawData <- file.path(sandboxRoot, "01_dw_prep", "011_rawdata")
  teamsWrkData <- file.path(sandboxRoot, "01_dw_prep", "013_wrkdata")
  for (d in c(teamsRawData, teamsWrkData)) dir.create(d, recursive = TRUE, showWarnings = FALSE)
  message("[OK] REVIEWER mode: writes go to ", sandboxRoot, "; the deposit is read only.")
}

# This repository's stages (01_dw_prep/README.md): 011_rawdata and
# 013_wrkdata here hold local copies only and never reach git.
dwMetaData <- file.path(rootFolder, "01_dw_prep", "010_metadata")
dwCodes    <- file.path(rootFolder, "01_dw_prep", "012_codes")
dwWrkData  <- file.path(rootFolder, "01_dw_prep", "013_wrkdata")

#----------------------------------------
# 7. Z: drive mirror of the deposit (advisory, never blocking)
#----------------------------------------
# A producer's dw_save() also writes the Z: mirror; dw_use() checks reads
# against it. zDrive in your user block overrides the default "Z:/".
# Timeout-bounded probe: dir.exists() on a mapped but unreachable drive
# letter (Z: off VPN) can block for the full SMB timeout.
.dw_drive_available <- function(root, timeout = 3) {
  is_drive_letter <- .Platform$OS.type == "windows" &&
    nchar(root) <= 3 && substr(root, 2, 2) == ":"
  if (!is_drive_letter) return(dir.exists(root))
  rc <- tryCatch(
    system2("cmd", c("/c", "vol", substr(root, 1, 2)),
            stdout = FALSE, stderr = FALSE, timeout = timeout),
    error = function(e) 1L, warning = function(w) 1L
  )
  isTRUE(rc == 0L)
}
network_root <- user_setting("zDrive")
if (!(is.character(network_root) && length(network_root) == 1 && nzchar(network_root))) {
  network_root <- "Z:/"
}
dw_z_available <- .dw_drive_available(network_root)
dwZDrive <- if (dw_z_available) file.path(network_root, "060.DW-MASTER") else NA_character_
if (dw_z_available && !dir.exists(dwZDrive)) {
  dw_z_available <- FALSE
  dwZDrive <- NA_character_
}
if (!dw_z_available) {
  message("[!] profile: the Z: mirror (", network_root, "060.DW-MASTER) is not available -- non-blocking.")
}

