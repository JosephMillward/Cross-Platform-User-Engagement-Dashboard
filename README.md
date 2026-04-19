# DHS Data Use Activity - Behavioral Analytics Dashboard

An R Shiny dashboard for analysing platform engagement data from the DHS Program, a USAID-funded initiative producing population and health survey data across 90+ countries since 1984. The dashboard demonstrates end-to-end behavioral analytics: from time series visualization and event annotation through causal inference modeling of individual program events.

Disclaimer
This dashboard is a portfolio demonstration built entirely on synthetic data generated to reflect the statistical properties of real program analytics without containing any proprietary, confidential, or personally identifiable information. It is not an official product of the DHS Program, Johns Hopkins University, the World Bank Group, or any affiliated organization, and does not represent, release, or reproduce any data or findings from those institutions.

DHS survey publication dates are drawn from the publicly available DHS API (dhsprogram.com) and are the only real data used in this project. All engagement metrics, program events, and country-level statistics are simulated.

The analytical methods demonstrated here — prophet forecasting, event study design, and Bayesian causal inference via CausalImpact — are standard open-source tools applied to a synthetic dataset for illustrative purposes only. Results should not be interpreted as findings about the DHS Program or any associated country programs.

---

## Methods

### Engagement Trends
Time series of five platform engagement metrics (in-country downloads, STATCompiler sessions, website visits, SDR sessions, mobile app sessions) with event overlays rendered as vertical dotted lines. Multiple simultaneous events are preserved as independent markers, each with its own hover tooltip.

### Prophet Forecasting
Bayesian structural time series forecasting via Meta's prophet package. The model captures yearly seasonality and long-run trend with a multiplicative seasonality mode. Confidence intervals represent the 80% posterior predictive interval.

### Event Study Design
For each event type, the dashboard computes the average platform engagement metric at each monthly offset from -6 to +6 months relative to each event date, then averages across all events of that type for the selected country. This reveals the shape of the behavioral response rather than collapsing it to a single before/after number. Bootstrap resampling (n=200) generates 95% confidence intervals around each trajectory line.

This approach is analogous to event study methodology in econometrics and financial research, adapted here for program analytics.

### CausalImpact (Individual Event Analysis)
For any specific event, the dashboard runs a Bayesian structural time series causal inference model using the CausalImpact package (Brodersen et al., 2015). The model:

1. Fits a state space model to the pre-event period
2. Projects a counterfactual (what engagement would have looked like without the event)
3. Estimates the causal effect as actual minus counterfactual with 95% posterior credible intervals
4. Reports absolute effect (avg monthly lift), relative effect (%), and posterior p-value

This is more rigorous than a simple pre/post comparison because it controls for pre-existing trend and seasonality rather than assuming a flat baseline.

---

## Data

The dashboard uses synthetic data preserving the statistical properties of real DHS program analytics: monthly seasonality reflecting survey release cycles, country-level heterogeneity, correlated metrics, and zero-inflation in low-volume countries.

DHS publication dates are loaded from the real public DHS API (api.dhsprogram.com), providing authentic event anchors for causal analysis.

In production, synthetic CSV imports could be replaced with SQL queries. Some details on general implementation are included below.

---

## Repository Structure

```
.
|-- app.R                             Main Shiny application including DHS API pulls
|-- data/
|   |-- generate_synthetic_data.R     Generates synthetic CSV files
|   |-- synthetic_metrics.csv         Generated: run script above first
|   `-- synthetic_events.csv          Generated: run script above first
`-- README.md
```

---

## Setup

### 1. Generate synthetic data

```r
source("data/generate_synthetic_data.R")
```

Creates data/synthetic_metrics.csv and data/synthetic_events.csv. These are already included in the repo, but these files can be run again at any point in your local system. The DHS API is called automatically for real publication dates.

### 2. Install dependencies

```r
install.packages(c(
  "shiny", "shinydashboard", "shinyjs", "shinycssloaders",
  "plotly", "dplyr", "tidyverse", "tidyr", "lubridate",
  "prophet", "CausalImpact", "zoo", "jsonlite", "readr",
  "stringr", "data.table", "conflicted"
))
```

prophet requires rstan as a backend. If installation fails:

```r
install.packages("rstan", repos = "https://cloud.r-project.org")
install.packages("prophet")
```

CausalImpact may require installation from GitHub:

```r
devtools::install_github("google/CausalImpact")
```

### 3. Run

```r
shiny::runApp("app.R")
```

---

## Production Database Connection

In production, live SQL data may be used. Naturally, these credentials cannot be included in this portfolio, but general steps for setting a live connection would include setting a database connection, including credentials and environment variables in an .Renviron, then replacing any read_csv() calls in app.r with dbGetQuery() calls using relevant SQL files.The rest of the application would remain unchanged.

---

## References

Brodersen, K.H., Gallusser, F., Koehler, J., Remy, N., Scott, S.L. (2015). Inferring causal impact using Bayesian structural time-series models. Annals of Applied Statistics, 9(1), 247-274.

Taylor, S.J. & Letham, B. (2018). Forecasting at scale. The American Statistician, 72(1), 37-45.

---

## Author

Joseph Millward, MHS
