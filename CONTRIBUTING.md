# Setup and Contribution Guide

## First-time setup

### 1. Clone and open

```bash
git clone https://github.com/[your-handle]/dhs-data-use-dashboard.git
cd dhs-data-use-dashboard
```

Open `dhs-data-use-dashboard.Rproj` in RStudio if you have one, or set your
working directory to the repo root.

### 2. Install R dependencies

The app installs missing packages automatically on first run, but you can
pre-install them to avoid delays:

```r
install.packages(c(
  "shiny", "shinydashboard", "shinyjs", "shinycssloaders",
  "plotly", "dplyr", "tidyverse", "tidyr", "lubridate",
  "readr", "stringr", "data.table", "zoo",
  "jsonlite", "conflicted", "rstudioapi"
))
```

**prophet** requires the `rstan` C++ compiler backend. Install in this order:

```r
# Step 1: rstan (compiles C++ — takes a few minutes)
install.packages("rstan", repos = "https://cloud.r-project.org")

# Step 2: prophet
install.packages("prophet")

# Verify
library(prophet)
```

**CausalImpact** is available on CRAN but the GitHub version is more current:

```r
# Option A: CRAN
install.packages("CausalImpact")

# Option B: GitHub (recommended)
install.packages("devtools")
devtools::install_github("google/CausalImpact")

# Verify
library(CausalImpact)
```

### 3. Generate synthetic data

Run once before launching the app. This creates the two CSV files the app
reads on startup and calls the live DHS API for real publication dates.

```r
source("data/generate_synthetic_data.R")
```

Expected output:

```
Generating synthetic metrics for 30 countries...
  ... 10 / 30
  ... 20 / 30
  ... 30 / 30
Written: data/synthetic_metrics.csv ( 3720 rows )
Fetching DHS publication dates from API...
  API returned 438 publication records
Written: data/synthetic_events.csv ( 892 rows )
Done.
```

If the DHS API is unavailable (network issues), the script falls back to
placeholder publication events and continues. The app will still run
correctly; only the DHS Publication event type will have limited data.

### 4. Launch the app

```r
shiny::runApp("app.R")
```

Or click "Run App" in RStudio with `app.R` open.

---

## Project structure

```
.
|-- app.R                              Main application (single file)
|-- METHODS.md                         Analytical design notes
|-- README.md                          Overview, setup, usage
|-- CONTRIBUTING.md                    This file
|-- .gitignore
|-- data/
|   |-- generate_synthetic_data.R      Run once to create CSVs below
|   |-- synthetic_metrics.csv          Engagement metrics (generated)
|   `-- synthetic_events.csv           Program events (generated)
```

---

## Deploying to shinyapps.io

```r
install.packages("rsconnect")
library(rsconnect)

# Authenticate once
rsconnect::setAccountInfo(
  name   = "your-account-name",
  token  = "your-token",
  secret = "your-secret"
)

# Deploy
rsconnect::deployApp(appDir = ".", appName = "dhs-data-use-dashboard")
```

The synthetic CSV files in `data/` will be bundled with the deployment
automatically. Do not include real DHS Excel files in the deployment bundle
— keep them out of the repo entirely (they are already in `.gitignore`).

**Environment variables on shinyapps.io**: If deploying with a live database
connection, set `DHS_DB_SERVER`, `DHS_DB_NAME`, `DHS_DB_USER`, and
`DHS_DB_PASSWORD` in the app's Environment Variables settings on the
shinyapps.io dashboard rather than in `.Renviron`.

---

## Common issues

**"Error sourcing app.R" on startup**
Usually a missing package. Run `install.packages()` for any package
listed in the `pkgs` vector at the top of `app.R`, then restart R.

**"Error in opening DHS api url**
Sometimes the DHS program api undergoes maintenance or server outage, meaning 
that communication and subsequent json pulls are not available. In these cases,
you must wait until the api is back online. This does not happen often, but may occur.

**"prophet" or "rstan" errors**
After a major R version upgrade, `rstan` needs to be reinstalled from
source. Run `install.packages("rstan", repos = "https://cloud.r-project.org")`
then `install.packages("prophet")`, and restart R before relaunching.

**Forecast shows "Requires 24+ months" for Global**
The synthetic data starts September 2013. If the date range filter has been
narrowed to fewer than 24 months, the forecast cannot run. Reset the date
range to the full available range in the sidebar.

**CausalImpact shows "Only N non-zero values"**
The selected metric is too sparse for the selected country over the
pre-event window. Switch to Website Visits or STATCompiler Sessions, which
have more consistent non-zero coverage, or select Global instead of a
low-volume country.

**Event study shows "Select at least one event type"**
Event type checkboxes are unchecked by default for faster initial load.
Tick one or more event types in the sidebar to compute the event study.
