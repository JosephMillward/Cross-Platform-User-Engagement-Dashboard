# =============================================================================
# generate_synthetic_data.R
# DHS Data Use Activity - Synthetic Data Generator
#
# Generates realistic fake engagement data that preserves the statistical
# properties of a real program analytics dataset:
#   - Monthly seasonality (peak Q1/Q2, trough Q3)
#   - Country-level heterogeneity (sparse low-income, dense middle-income)
#   - Trend growth over time with occasional structural breaks
#   - Correlated metrics (downloads co-move with web sessions)
#   - Event-driven spikes plausibly linked to DHS publication dates
#
# Output: data/synthetic_metrics.csv, data/synthetic_events.csv
# The DHS API is still used for real publication dates (public data).
# =============================================================================

set.seed(20240401)  # reproducible
setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
library(tidyverse)
library(lubridate)
library(jsonlite)

# -----------------------------------------------------------------------------
# 1. Country roster and base parameters
# -----------------------------------------------------------------------------
# 30 representative DHS countries spanning all regions and data volumes
countries <- tribble(
  ~country,              ~region,        ~base_dl, ~base_web, ~base_stat, ~base_sdr, ~base_app,
  "Kenya",               "ESAF",         800,      450,       180,        90,        60,
  "Nigeria",             "WCA",          650,      380,       150,        70,        45,
  "Ethiopia",            "ESAF",         500,      290,       120,        55,        35,
  "Tanzania",            "ESAF",         420,      240,       100,        48,        30,
  "Uganda",              "ESAF",         370,      210,        88,        42,        25,
  "Ghana",               "WCA",          310,      175,        72,        35,        20,
  "Senegal",             "WCA",          280,      158,        65,        31,        18,
  "Mali",                "WCA",          180,      100,        42,        20,        12,
  "Mozambique",          "ESAF",         160,       90,        37,        18,        10,
  "Zambia",              "ESAF",         150,       85,        34,        16,         9,
  "Rwanda",              "ESAF",         200,      112,        46,        22,        13,
  "Malawi",              "ESAF",         140,       79,        32,        15,         8,
  "Zimbabwe",            "ESAF",         130,       73,        30,        14,         8,
  "Cambodia",            "APAC",         220,      124,        51,        24,        15,
  "Nepal",               "APAC",         190,      107,        44,        21,        12,
  "Bangladesh",          "APAC",         310,      175,        72,        35,        20,
  "Pakistan",            "APAC",         270,      152,        63,        30,        17,
  "Myanmar",             "APAC",         150,       85,        34,        16,         9,
  "India",               "APAC",         480,      270,       111,        53,        32,
  "Haiti",               "LATAM",        160,       90,        37,        18,        10,
  "Dominican Republic",  "LATAM",        140,       79,        32,        15,         8,
  "Honduras",            "LATAM",        120,       68,        28,        13,         7,
  "Guatemala",           "LATAM",        115,       65,        27,        13,         7,
  "Jordan",              "MENA",         200,      113,        46,        22,        13,
  "Egypt",               "MENA",         340,      191,        79,        38,        22,
  "Morocco",             "MENA",         180,      101,        42,        20,        11,
  "Afghanistan",         "APAC",          80,       45,        19,         9,         5,
  "Liberia",             "WCA",           70,       39,        16,         8,         4,
  "Sierra Leone",        "WCA",           60,       34,        14,         7,         3,
  "Guinea",              "WCA",           55,       31,        13,         6,         3
)

date_seq <- seq(as.Date("2013-09-01"), as.Date("2023-03-01"), by = "month")
n_months <- length(date_seq)

# -----------------------------------------------------------------------------
# 2. Seasonality and trend components
# -----------------------------------------------------------------------------
# Yearly seasonality: peak Jan-Apr (post-survey release season), trough Aug-Sep
month_factor <- c(1.25, 1.30, 1.28, 1.22, 1.10, 1.05,
                  0.92, 0.85, 0.88, 0.95, 1.05, 1.15)

# Slow upward trend: ~3% per year compounded
trend_multiplier <- cumprod(rep(1 + 0.03/12, n_months))

# Occasional platform-wide events that create global spikes
global_shock_months <- c(25, 50, 72, 90)  # indices into date_seq
global_shock_size   <- c(1.4, 1.3, 1.5, 1.35)

make_global_multiplier <- function() {
  mult <- rep(1, n_months)
  for (i in seq_along(global_shock_months)) {
    idx <- global_shock_months[i]
    # Spike decays over 3 months
    for (j in 0:3) {
      if (idx + j <= n_months) {
        mult[idx + j] <- mult[idx + j] * (global_shock_size[i] ^ (1 - j * 0.25))
      }
    }
  }
  mult
}
global_mult <- make_global_multiplier()

# -----------------------------------------------------------------------------
# 3. Generate per-country metrics
# -----------------------------------------------------------------------------
generate_country_metrics <- function(country_row) {
  nm        <- country_row$country
  base_vals <- list(
    Downloads.Internal      = country_row$base_dl,
    Website                 = country_row$base_web,
    STATCompiler            = country_row$base_stat,
    Spatial.Data.Repository = country_row$base_sdr,
    Mobile.App              = country_row$base_app
  )

  rows <- lapply(seq_along(date_seq), function(i) {
    d   <- date_seq[i]
    mo  <- as.integer(format(d, "%m"))
    sea <- month_factor[mo]
    trn <- trend_multiplier[i]
    glb <- global_mult[i]

    # Country-specific noise: log-normal so values stay positive
    noise <- rlnorm(5, meanlog = 0, sdlog = 0.18)

    # Sparse countries get extra zero-inflation
    sparsity <- if (country_row$base_dl < 100) 0.35 else
                if (country_row$base_dl < 200) 0.15 else 0.05
    zero_mask <- rbinom(5, 1, 1 - sparsity)

    vals <- mapply(function(base, n, z) {
      max(0L, as.integer(round(base * sea * trn * glb * n * z)))
    }, base_vals, noise, zero_mask)

    tibble(
      Date                    = d,
      Survey.Country          = nm,
      Downloads.Internal      = vals[1],
      Website                 = vals[2],
      STATCompiler            = vals[3],
      Spatial.Data.Repository = vals[4],
      Mobile.App              = vals[5]
    )
  })

  bind_rows(rows)
}

cat("Generating synthetic metrics for", nrow(countries), "countries...\n")
metrics_list <- lapply(seq_len(nrow(countries)), function(i) {
  if (i %% 10 == 0) cat("  ...", i, "/", nrow(countries), "\n")
  generate_country_metrics(countries[i, ])
})
Metrics_synth <- bind_rows(metrics_list)

# Downloads.External: correlated with Internal but from a different user pool
Metrics_synth <- Metrics_synth %>%
  mutate(Downloads.External = as.integer(
    round(Downloads.Internal * runif(n(), 0.4, 0.9) * rlnorm(n(), 0, 0.12))
  ))

write_csv(Metrics_synth, "data/synthetic_metrics.csv")
cat("Written: data/synthetic_metrics.csv (", nrow(Metrics_synth), "rows )\n")

# -----------------------------------------------------------------------------
# 4. Fetch real DHS publication dates from public API
# -----------------------------------------------------------------------------
cat("Fetching DHS publication dates from API...\n")
tryCatch({
  url      <- "http://api.dhsprogram.com/rest/dhs/v8/surveys/.json"
  jsondata <- fromJSON(url)
  DHS_API  <- as.data.frame(jsondata$Data) %>%
    select(SurveyYear, SurveyType, CountryName, PublicationDate) %>%
    mutate(Date           = as.Date(PublicationDate),
           Survey.Country = CountryName,
           event_type     = "DHS Publication",
           event_label    = paste(SurveyYear, SurveyType)) %>%
    filter(!is.na(Date), Survey.Country %in% countries$country) %>%
    select(Date, Survey.Country, event_type, event_label)
  cat("  API returned", nrow(DHS_API), "publication records\n")
}, error = function(e) {
  cat("  API unavailable, generating placeholder publication events\n")
  DHS_API <<- bind_rows(lapply(countries$country[1:10], function(c) {
    tibble(
      Date           = as.Date(c("2015-06-01","2018-09-01","2022-03-01")),
      Survey.Country = c,
      event_type     = "DHS Publication",
      event_label    = paste(c(2015, 2018, 2022), "DHS")
    )
  }))
})

# -----------------------------------------------------------------------------
# 5. Generate synthetic program events
# -----------------------------------------------------------------------------
# Activities, trainings, dissemination events placed near real pub dates
# where possible, with realistic clustering and some standalone events

event_types_to_generate <- list(
  list(type = "Data Use Activity",
       labels = c("Data quality review workshop",
                  "National stakeholder briefing",
                  "Sub-national data planning session",
                  "Ministry of Health data review",
                  "Survey data utilization workshop",
                  "Results dissemination to partners")),
  list(type = "MEL Training",
       labels = c("Geospatial data analysis training",
                  "DHS data analysis workshop",
                  "Survey dissemination training",
                  "Advanced data analysis seminar",
                  "Data visualization training")),
  list(type = "Dissemination",
       labels = c("National launch event",
                  "Regional policy dialogue",
                  "Press conference and media briefing",
                  "Parliamentarian briefing",
                  "Academic conference presentation",
                  "Development partner briefing"))
)

generate_program_events <- function(pub_events) {
  results <- list()

  for (ev_def in event_types_to_generate) {
    # Place ~60% of events within 90 days of a publication
    n_anchored  <- round(nrow(pub_events) * 0.6)
    n_freestand <- round(nrow(pub_events) * 0.4)

    anchored <- pub_events %>%
      sample_n(min(n_anchored, nrow(pub_events)), replace = TRUE) %>%
      mutate(
        Date       = Date + sample(-30:90, n(), replace = TRUE),
        Date       = as.Date(ifelse(Date < min(date_seq), min(date_seq), Date)),
        event_type  = ev_def$type,
        event_label = sample(ev_def$labels, n(), replace = TRUE)
      ) %>%
      select(Date, Survey.Country, event_type, event_label)

    # Freestanding events spread across timeline
    freestand_countries <- sample(countries$country, n_freestand, replace = TRUE)
    freestand <- tibble(
      Date           = sample(date_seq, n_freestand, replace = TRUE),
      Survey.Country = freestand_countries,
      event_type     = ev_def$type,
      event_label    = sample(ev_def$labels, n_freestand, replace = TRUE)
    )

    results <- c(results, list(anchored), list(freestand))
  }

  # Add Further Analysis publications
  fa_labels <- c(
    "Determinants of child stunting: evidence from DHS",
    "Antenatal care utilization and maternal outcomes",
    "Contraceptive prevalence trends 2010-2020",
    "Wealth index and health service utilization",
    "Gender disparities in immunization coverage",
    "Urban-rural differentials in under-5 mortality",
    "Adolescent fertility and educational attainment",
    "Male involvement in family planning programs"
  )
  fa_countries <- sample(countries$country, 60, replace = TRUE)
  fa_events <- tibble(
    Date           = sample(date_seq, 60, replace = TRUE),
    Survey.Country = fa_countries,
    event_type     = "Further Analysis",
    event_label    = sample(fa_labels, 60, replace = TRUE)
  )
  results <- c(results, list(fa_events))

  bind_rows(results) %>%
    filter(Date >= min(date_seq), Date <= max(date_seq)) %>%
    arrange(Survey.Country, Date)
}

Events_program <- generate_program_events(DHS_API)
Events_synth   <- bind_rows(DHS_API, Events_program) %>%
  arrange(Survey.Country, Date)

write_csv(Events_synth, "data/synthetic_events.csv")
cat("Written: data/synthetic_events.csv (", nrow(Events_synth), "rows)\n")

# -----------------------------------------------------------------------------
# 6. Quick validation plots
# -----------------------------------------------------------------------------
cat("\nValidation summary:\n")
cat("  Countries:       ", n_distinct(Metrics_synth$Survey.Country), "\n")
cat("  Date range:      ", format(min(Metrics_synth$Date)), "to",
    format(max(Metrics_synth$Date)), "\n")
cat("  Metric rows:     ", nrow(Metrics_synth), "\n")
cat("  Event rows:      ", nrow(Events_synth), "\n")
cat("  Event types:     ", paste(unique(Events_synth$event_type), collapse = ", "), "\n")
cat("\nGlobal monthly Downloads.Internal (first 6 months):\n")
Metrics_synth %>%
  group_by(Date) %>%
  summarise(total = sum(Downloads.Internal)) %>%
  head(6) %>%
  print()
cat("\nDone. Load synthetic data in app.R with:\n")
cat("  Metrics <- read_csv('data/synthetic_metrics.csv')\n")
cat("  Events  <- read_csv('data/synthetic_events.csv')\n")
