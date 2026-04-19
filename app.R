# =============================================================================
# app.R  |  DHS Program Data Use Activity - Analytics Dashboard
# Author: Joseph Millward, MHS
# GitHub: https://github.com/[your-handle]/dhs-data-use-dashboard
#
# Three-tab Shiny dashboard for behavioural analytics of DHS platform usage:
#   Tab 1 - Engagement Trends: time series with event overlays
#   Tab 2 - Forecast & Impact: prophet forecasting + event study design
#   Tab 3 - Event Analysis: individual event CausalImpact (BSTS)
#
# Data sources:
#   - Synthetic engagement metrics (data/synthetic_metrics.csv)
#   - DHS publication dates from public API (dhsprogram.com)
#   - Synthetic program events (data/synthetic_events.csv)
#
# In production these CSVs would be replaced by SQL queries.
# See sql/04_r_database_connection.R for the connection pattern.
# =============================================================================

rm(list = ls())
setwd(dirname(rstudioapi::getActiveDocumentContext()$path))

# --- Packages -----------------------------------------------------------------
pkgs <- c(
  "conflicted", "jsonlite", "data.table", "shinycssloaders", "zoo",
  "shinydashboard", "shinyjs", "shiny", "dplyr", "tidyverse", "tidyr",
  "plotly", "readr", "stringr", "prophet", "lubridate", "rstudioapi",
  "CausalImpact"
)
new.pkgs <- pkgs[!(pkgs %in% installed.packages()[, "Package"])]
if (length(new.pkgs)) install.packages(new.pkgs)

library(conflicted)
library(readr);   library(stringr);  library(tidyverse); library(dplyr)
library(shiny);   library(plotly);   library(jsonlite);  library(data.table)
library(shinycssloaders); library(zoo); library(shinydashboard); library(shinyjs)
library(tidyr);   library(prophet);  library(lubridate); library(CausalImpact)

conflicts_prefer(shinydashboard::box)
conflicts_prefer(plotly::layout)
conflicts_prefer(plotly::subplot)
conflicts_prefer(dplyr::filter)
conflicts_prefer(dplyr::select)
conflicts_prefer(dplyr::rename)
conflicts_prefer(dplyr::mutate)
conflicts_prefer(dplyr::summarise)
conflicts_prefer(dplyr::summarize)
conflicts_prefer(shiny::validate)

# --- Helpers ------------------------------------------------------------------
harmonise_names <- function(df) {
  name_map <- c(
    "Antigua and Barbuda"                   = "Antigua & Barbuda",
    "Bosnia and Herzegovina"                = "Bosnia & Herzegovina",
    "Brunei Darussalam"                     = "Brunei",
    "Guinea Bissau"                         = "Guinea-Bissau",
    "Iran (islamic Republic Of)"            = "Iran",
    "Lao People's Democratic Republic"      = "Laos",
    "Micronesia Federated States of"        = "Micronesia",
    "Korea Democratic People's Republic of" = "North Korea",
    "Korea Republic of"                     = "South Korea",
    "Syrian Arab Republic"                  = "Syria",
    "Taiwan Province of China"              = "Taiwan",
    "Turkiye"                               = "Turkey"
  )
  df$Survey.Country <- dplyr::recode(df$Survey.Country, !!!name_map)
  df %>% dplyr::filter(!is.na(Survey.Country),
                       !grepl("Unknown", Survey.Country))
}

error_plot <- function(msg) {
  words <- strsplit(msg, " ")[[1]]
  lines <- character(0); cur_line <- ""
  for (w in words) {
    candidate <- if (nchar(cur_line) == 0) w else paste(cur_line, w)
    if (nchar(candidate) > 65 && nchar(cur_line) > 0) {
      lines <- c(lines, cur_line); cur_line <- w
    } else { cur_line <- candidate }
  }
  if (nchar(cur_line) > 0) lines <- c(lines, cur_line)
  plot_ly() %>%
    plotly::layout(
      xaxis = list(visible = FALSE, zeroline = FALSE),
      yaxis = list(visible = FALSE, zeroline = FALSE),
      plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc",
      annotations = list(list(
        text = paste(lines, collapse = "<br>"),
        x = 0.5, y = 0.5, xref = "paper", yref = "paper",
        showarrow = FALSE,
        font = list(size = 13, color = "#C0392B"), align = "center"
      ))
    )
}

# --- Data Loading -------------------------------------------------------------
num_cols <- c("Downloads.External", "Downloads.Internal",
              "STATCompiler", "Website", "Spatial.Data.Repository", "Mobile.App")

cat("Loading synthetic metrics...\n")
Metrics_raw <- read_csv("data/synthetic_metrics.csv", show_col_types = FALSE) %>%
  dplyr::mutate(Date = as.Date(Date)) %>%
  harmonise_names()
Metrics_raw[num_cols][is.na(Metrics_raw[num_cols])] <- 0

Global_metrics <- Metrics_raw %>%
  dplyr::group_by(Date) %>%
  dplyr::summarise(dplyr::across(dplyr::all_of(num_cols), ~sum(.x, na.rm = TRUE)),
                   .groups = "drop") %>%
  dplyr::mutate(Survey.Country = "Global")

Metrics <- dplyr::bind_rows(Metrics_raw, Global_metrics) %>%
  dplyr::distinct(Date, Survey.Country, .keep_all = TRUE)

cat("Loading synthetic program events...\n")
Events_program <- read_csv("data/synthetic_events.csv", show_col_types = FALSE) %>%
  dplyr::mutate(Date = as.Date(Date)) %>%
  harmonise_names() %>%
  dplyr::filter(!is.na(Date))

cat("Fetching DHS publication dates from API...\n")
Events_pub <- tryCatch({
  jsondata <- fromJSON("http://api.dhsprogram.com/rest/dhs/v8/surveys/.json")
  as.data.frame(jsondata$Data) %>%
    dplyr::select(SurveyYear, SurveyType, CountryName, PublicationDate) %>%
    dplyr::transmute(
      Date           = as.Date(PublicationDate),
      Survey.Country = CountryName,
      event_type     = "DHS Publication",
      event_label    = paste(SurveyYear, SurveyType)
    ) %>%
    harmonise_names() %>%
    dplyr::filter(!is.na(Date))
}, error = function(e) {
  message("DHS API unavailable: ", conditionMessage(e))
  data.frame()
})

Events_country <- dplyr::bind_rows(Events_program, Events_pub) %>%
  dplyr::filter(!is.na(Date))

Events <- dplyr::bind_rows(
  Events_country,
  Events_country %>% dplyr::mutate(Survey.Country = "Global")
)

event_colors <- c(
  "Data Use Activity" = "#E74C3C",
  "MEL Training"      = "#2980B9",
  "DHS Publication"   = "#27AE60",
  "Dissemination"     = "#E67E22",
  "Further Analysis"  = "#8E44AD"
)
event_types_all <- names(event_colors)

cat("Ready. Metrics:", nrow(Metrics), "rows |",
    "Events:", nrow(Events), "rows |",
    "Countries:", n_distinct(Metrics$Survey.Country), "\n")

# --- Analytical Helpers -------------------------------------------------------

complete_metrics <- function(df) {
  all_dates <- seq(min(df$Date, na.rm = TRUE),
                   max(df$Date, na.rm = TRUE), by = "month")
  df %>%
    tidyr::complete(Date = all_dates) %>%
    tidyr::replace_na(as.list(setNames(rep(0, length(num_cols)), num_cols)))
}

fit_forecast <- function(metrics_data, metric_col, horizon_months = 12) {
  df <- metrics_data %>%
    dplyr::filter(!is.na(.data[[metric_col]]), .data[[metric_col]] > 0) %>%
    dplyr::transmute(ds = Date, y = as.numeric(.data[[metric_col]])) %>%
    dplyr::arrange(ds)
  if (nrow(df) < 24) return(NULL)
  suppressMessages({
    m <- prophet(df, yearly.seasonality = TRUE, weekly.seasonality = FALSE,
                 daily.seasonality = FALSE, seasonality.mode = "multiplicative",
                 changepoint.prior.scale = 0.05)
  })
  last_date    <- max(df$ds)
  future_dates <- seq(last_date, by = "month", length.out = horizon_months + 1)[-1]
  fc           <- predict(m, data.frame(ds = c(df$ds, future_dates)))
  list(model = m, forecast = fc, last_observed = last_date)
}

compute_event_study <- function(metrics_data, events_data, metric_col,
                                window_months = 6, n_boot = 200) {
  md      <- complete_metrics(metrics_data)
  offsets <- seq(-window_months, window_months, by = 1)

  results <- lapply(event_types_all, function(etype) {
    edates <- events_data %>%
      dplyr::filter(event_type == etype) %>%
      dplyr::pull(Date) %>% unique()
    if (length(edates) == 0) return(NULL)

    event_matrix <- lapply(edates, function(ed) {
      ed <- as.Date(ed, origin = "1970-01-01")
      sapply(offsets, function(mo) {
        target <- as.Date(ed + months(mo))
        closest <- md %>%
          dplyr::mutate(diff = abs(as.numeric(
            difftime(Date, target, units = "days")))) %>%
          dplyr::filter(diff <= 15) %>%
          dplyr::slice_min(diff, n = 1, with_ties = FALSE)
        if (nrow(closest) == 0) return(NA_real_)
        as.numeric(closest[[metric_col]])
      })
    })

    mat <- do.call(rbind, event_matrix)
    if (is.null(dim(mat))) return(NULL)
    avg_vals <- colMeans(mat, na.rm = TRUE)
    n_valid  <- colSums(!is.na(mat))

    if (nrow(mat) >= 2) {
      boot_means <- replicate(n_boot, {
        idx <- sample(seq_len(nrow(mat)), replace = TRUE)
        colMeans(mat[idx, , drop = FALSE], na.rm = TRUE)
      })
      ci_lo <- apply(boot_means, 1, quantile, 0.025, na.rm = TRUE)
      ci_hi <- apply(boot_means, 1, quantile, 0.975, na.rm = TRUE)
    } else {
      ci_lo <- ci_hi <- rep(NA_real_, length(offsets))
    }

    tibble::tibble(event_type = etype, month_offset = offsets,
                   avg_value = avg_vals, ci_lo = ci_lo, ci_hi = ci_hi,
                   n_events = n_valid)
  })

  dplyr::bind_rows(results) %>% dplyr::filter(!is.nan(avg_value))
}

run_causal_impact <- function(metrics_data, event_date, metric_col,
                               pre_months = 12, post_months = 6) {
  md <- complete_metrics(metrics_data) %>% dplyr::arrange(Date)
  event_month <- as.Date(format(as.Date(event_date), "%Y-%m-01"))
  pre_start   <- event_month %m-% months(pre_months)
  pre_end     <- event_month %m-% months(1)
  post_start  <- event_month
  post_end    <- event_month %m+% months(post_months)

  window_data   <- md %>% dplyr::filter(Date >= pre_start, Date <= post_end)
  pre_data      <- window_data %>% dplyr::filter(Date <= pre_end)
  post_data     <- window_data %>% dplyr::filter(Date >= post_start)
  n_pre_nonzero <- sum(pre_data[[metric_col]] > 0, na.rm = TRUE)

  if (nrow(pre_data) < 3)
    return(list(error = sprintf(
      "Only %d pre-event months found (need 3+). Pre window: %s to %s.",
      nrow(pre_data), format(pre_start, "%b %Y"), format(pre_end, "%b %Y"))))
  if (nrow(post_data) < 1)
    return(list(error = sprintf(
      "No post-event data after %s. Event may fall at end of data range.",
      format(event_month, "%b %Y"))))
  if (n_pre_nonzero < 2)
    return(list(error = sprintf(
      "Only %d non-zero pre-event values for '%s' (%s to %s). Try a higher-volume metric or Global.",
      n_pre_nonzero, metric_col,
      format(pre_start, "%b %Y"), format(pre_end, "%b %Y"))))

  y <- zoo::zoo(window_data[[metric_col]], as.POSIXct(window_data$Date))
  tryCatch(
    suppressWarnings(
      CausalImpact(y,
                   pre.period  = as.POSIXct(c(min(pre_data$Date),  pre_end)),
                   post.period = as.POSIXct(c(post_start, max(post_data$Date))))
    ),
    error = function(e) list(error = paste("Model error:", conditionMessage(e)))
  )
}

# --- Custom CSS ---------------------------------------------------------------
custom_css <- "
  body, html { background:#F0F2F5 !important; font-family:'Segoe UI',Arial,sans-serif; }
  .content-wrapper, .main-footer { background:#F0F2F5 !important; }
  .main-header .navbar, .main-header .logo {
    background:#1A2744 !important; border-bottom:3px solid #C8102E !important; color:#FFFFFF !important; }
  .main-header .logo { font-weight:700; font-size:15px; letter-spacing:0.5px; }
  .main-sidebar { background:#1A2744 !important; }
  .sidebar-menu > li > a { color:#A0AEC0 !important; font-size:13px; border-left:3px solid transparent; transition:all 0.2s; }
  .sidebar-menu > li.active > a, .sidebar-menu > li > a:hover {
    color:#FFFFFF !important; background:rgba(200,16,46,0.15) !important; border-left:3px solid #C8102E !important; }
  .sidebar-menu > li > a > .fa { color:#718096; margin-right:8px; }
  .sidebar-menu > li.active > a > .fa { color:#C8102E !important; }
  .sidebar-label { padding:10px 15px 4px; color:#718096; font-size:10px; font-weight:700; letter-spacing:1.2px; text-transform:uppercase; }
  .main-sidebar .form-control, .main-sidebar .selectize-input {
    background:#243154 !important; border:1px solid #2D3F6B !important; color:#E2E8F0 !important; border-radius:4px; font-size:12px; }
  .main-sidebar .selectize-dropdown { background:#243154 !important; color:#E2E8F0 !important; }
  .main-sidebar .selectize-dropdown .option:hover { background:#C8102E !important; }
  .main-sidebar .control-label { color:#A0AEC0 !important; font-size:11px; font-weight:600; }
  .main-sidebar hr { border-color:#2D3F6B; margin:10px 15px; }
  .main-sidebar .checkbox label { color:#A0AEC0 !important; font-size:12px; }
  .main-sidebar .checkbox input[type=checkbox] { accent-color:#C8102E; }
  .main-sidebar .irs-bar, .main-sidebar .irs-bar-edge { background:#C8102E !important; border-color:#C8102E !important; }
  .main-sidebar .irs-single, .main-sidebar .irs-from, .main-sidebar .irs-to { background:#C8102E !important; }
  .main-sidebar .irs-line { background:#2D3F6B !important; }
  .main-sidebar .irs-min, .main-sidebar .irs-max { color:#718096 !important; font-size:10px; }
  .main-sidebar .input-daterange input {
    background:#243154 !important; border:1px solid #2D3F6B !important; color:#E2E8F0 !important; font-size:11px; text-align:center; }
  .main-sidebar .input-group-addon { background:#2D3F6B !important; border-color:#2D3F6B !important; color:#A0AEC0 !important; }
  .box { border-radius:8px !important; border:none !important;
    box-shadow:0 1px 4px rgba(0,0,0,0.08),0 2px 12px rgba(0,0,0,0.04) !important;
    background:#FFFFFF !important; margin-bottom:16px !important; }
  .box-header { background:#FFFFFF !important; border-bottom:1px solid #EDF2F7 !important;
    border-radius:8px 8px 0 0 !important; padding:12px 18px !important; }
  .box-header.with-border { border-bottom:1px solid #EDF2F7 !important; }
  .box-title { font-size:13px !important; font-weight:700 !important; color:#1A2744 !important; letter-spacing:0.2px; }
  .box.box-primary { border-left:4px solid #1A2744 !important; }
  .box.box-info    { border-left:4px solid #C8102E !important; }
  .box.box-primary.box-solid > .box-header, .box.box-info.box-solid > .box-header {
    background:#FFFFFF !important; color:#1A2744 !important; }
  .help-block { color:#718096 !important; font-size:11px !important; margin-top:6px; }
  table.dataTable th, .shiny-table th {
    background:#1A2744; color:#FFFFFF; padding:8px 12px; font-weight:600; font-size:11px; letter-spacing:0.5px; text-transform:uppercase; }
  table.dataTable td, .shiny-table td { padding:7px 12px; border-bottom:1px solid #EDF2F7; color:#2D3748; font-size:12px; }
  table.dataTable tr:nth-child(even) td, .shiny-table tr:nth-child(even) td { background:#F7FAFC; }
  ::-webkit-scrollbar { width:6px; height:6px; }
  ::-webkit-scrollbar-track { background:#F0F2F5; }
  ::-webkit-scrollbar-thumb { background:#CBD5E0; border-radius:3px; }
"

# --- UI -----------------------------------------------------------------------
ui <- dashboardPage(
  skin = "black",
  dashboardHeader(title = tags$span("DHS Data Use Monitor")),

  dashboardSidebar(
    sidebarMenu(
      menuItem("Engagement Trends", tabName = "trends",   icon = icon("chart-bar")),
      menuItem("Forecast & Impact", tabName = "forecast", icon = icon("chart-line")),
      menuItem("Event Analysis",    tabName = "causal",   icon = icon("flask"))
    ),
    tags$div(class = "sidebar-label", "Filters"),
    selectizeInput("country", "Country",
      choices  = c("Global", sort(unique(
        Metrics$Survey.Country[Metrics$Survey.Country != "Global"]))),
      selected = "Global"),
    dateRangeInput("daterange", "Date range",
      start = min(Metrics$Date, na.rm = TRUE),
      end   = max(Metrics$Date, na.rm = TRUE),
      min   = min(Metrics$Date, na.rm = TRUE),
      max   = max(Metrics$Date, na.rm = TRUE)),

    tags$div(class = "sidebar-label", "Event types"),
    # Unchecked by default: faster initial load, user opts in
    checkboxGroupInput("event_filter", label = NULL,
      choices  = event_types_all,
      selected = character(0)),

    tags$div(class = "sidebar-label", "Forecast"),
    selectInput("forecast_metric", "Metric",
      choices = c(
        "In-country Downloads"  = "Downloads.Internal",
        "STATCompiler Sessions" = "STATCompiler",
        "Website Visits"        = "Website",
        "SDR Sessions"          = "Spatial.Data.Repository",
        "Mobile App Sessions"   = "Mobile.App")),
    sliderInput("horizon", "Horizon (months)", min = 3, max = 24, value = 12),

    tags$div(class = "sidebar-label", "Individual event"),
    selectInput("ci_event_type", "Event type",
      choices = event_types_all, selected = "DHS Publication"),
    uiOutput("ci_event_selector"),
    sliderInput("ci_pre_months",  "Pre-event months",  min = 6,  max = 24, value = 12),
    sliderInput("ci_post_months", "Post-event months", min = 3,  max = 12, value = 6)
  ),

  dashboardBody(
    tags$style(HTML(custom_css)),
    tags$style(HTML("html, body { overflow: auto }")),
    useShinyjs(),

    tabItems(

      tabItem(tabName = "trends",
        fluidRow(
          shinydashboard::box(
            width = 12, status = "primary", solidHeader = TRUE,
            title = tags$span(icon("chart-bar", style = "color:#C8102E;margin-right:6px;"),
                              "Engagement Over Time"),
            tags$p(style = "color:#718096;font-size:11px;margin:0 0 12px;",
              "Select event types in the sidebar to overlay them as vertical lines. ",
              "Hover diamond markers for event details."),
            shinycssloaders::withSpinner(plotlyOutput("p_internal", height = "280px"), color = "#C8102E"),
            br(),
            shinycssloaders::withSpinner(plotlyOutput("p_statcomp", height = "220px"), color = "#C8102E"),
            br(),
            shinycssloaders::withSpinner(plotlyOutput("p_website",  height = "220px"), color = "#C8102E"),
            br(),
            shinycssloaders::withSpinner(plotlyOutput("p_sdr",      height = "220px"), color = "#C8102E"),
            br(),
            shinycssloaders::withSpinner(plotlyOutput("p_mobile",   height = "220px"), color = "#C8102E")
          )
        )
      ),

      tabItem(tabName = "forecast",
        fluidRow(
          shinydashboard::box(
            width = 12, status = "primary", solidHeader = TRUE,
            title = tags$span(icon("chart-line", style = "color:#C8102E;margin-right:6px;"),
                              "Metric Forecast with 80% Confidence Interval"),
            tags$p(style = "color:#718096;font-size:11px;margin:0 0 12px;",
              "Bars = actuals. Dotted line = model fit. ",
              "Dashed line + shaded band = prophet forecast + 80% CI."),
            shinycssloaders::withSpinner(plotlyOutput("forecast_plot", height = "420px"), color = "#C8102E")
          )
        ),
        fluidRow(
          shinydashboard::box(
            width = 6, status = "info", solidHeader = TRUE,
            title = tags$span(icon("wave-square", style = "color:#C8102E;margin-right:6px;"),
                              "Event Study: avg trajectory +/-6 months"),
            tags$p(style = "color:#718096;font-size:11px;margin:0 0 12px;",
              "Lines = avg metric value at each month relative to event date (month 0). ",
              "Shaded bands = 95% bootstrap CI across all events of each type. ",
              "For a single-event analysis, use the Event Analysis tab."),
            shinycssloaders::withSpinner(plotlyOutput("impact_plot", height = "340px"), color = "#C8102E")
          ),
          shinydashboard::box(
            width = 6, status = "info", solidHeader = TRUE,
            title = tags$span(icon("layer-group", style = "color:#C8102E;margin-right:6px;"),
                              "Trend & Seasonality Decomposition"),
            tags$p(style = "color:#718096;font-size:11px;margin:0 0 12px;",
              "Trend and annual seasonality components extracted by the prophet model."),
            shinycssloaders::withSpinner(plotlyOutput("decomp_plot", height = "340px"), color = "#C8102E")
          )
        )
      ),

      tabItem(tabName = "causal",
        fluidRow(
          shinydashboard::box(
            width = 12, status = "primary", solidHeader = TRUE,
            title = tags$span(icon("flask", style = "color:#C8102E;margin-right:6px;"),
                              "CausalImpact: Bayesian Causal Effect Estimate"),
            tags$p(style = "color:#718096;font-size:11px;margin:0;",
              "Select an event type and specific event in the sidebar. ",
              "CausalImpact (Brodersen et al., 2015) fits a Bayesian structural time series ",
              "to the pre-event period, projects a counterfactual, and estimates the causal ",
              "effect as actual minus counterfactual. A significant effect appears when ",
              "post-event actuals fall consistently outside the 95% credible interval band.")
          )
        ),
        fluidRow(
          shinydashboard::box(
            width = 8, status = "primary", solidHeader = TRUE,
            title = tags$span(icon("eye", style = "color:#C8102E;margin-right:6px;"),
                              "Observed vs. Counterfactual"),
            shinycssloaders::withSpinner(plotlyOutput("ci_main_plot", height = "320px"), color = "#C8102E")
          ),
          shinydashboard::box(
            width = 4, status = "info", solidHeader = TRUE,
            title = tags$span(icon("table", style = "color:#C8102E;margin-right:6px;"),
                              "Effect Summary"),
            tableOutput("ci_summary_table"),
            "Absolute effect = avg monthly lift.", tags$br(),
            "Relative effect = % change vs. counterfactual.", tags$br(),
            "p-value = probability that the observed lift or decline occurred by chance. Values below 0.05 suggest a real effect unlikely explained by noise alone.")
        ),
        fluidRow(
          shinydashboard::box(
            width = 12, status = "info", solidHeader = TRUE,
            title = tags$span(icon("arrows-alt-v", style = "color:#C8102E;margin-right:6px;"),
                              "Pointwise Causal Effect (actual minus counterfactual, per month)"),
            shinycssloaders::withSpinner(plotlyOutput("ci_effect_plot", height = "240px"), color = "#C8102E")
          )
        )
      )
    )
  )
)

# --- Server -------------------------------------------------------------------
server <- function(input, output, session) {

  metrics_filtered <- reactive({
    Metrics %>%
      dplyr::filter(Survey.Country == input$country,
                    Date >= input$daterange[1],
                    Date <= input$daterange[2])
  })

  events_filtered <- reactive({
    if (length(input$event_filter) == 0) return(dplyr::filter(Events, FALSE))
    Events %>%
      dplyr::filter(Survey.Country == input$country,
                    event_type %in% input$event_filter,
                    !is.na(Date),
                    Date >= input$daterange[1],
                    Date <= input$daterange[2])
  })

  ci_events_available <- reactive({
    Events %>%
      dplyr::filter(Survey.Country == input$country,
                    event_type == input$ci_event_type,
                    !is.na(Date)) %>%
      dplyr::mutate(label = paste0(event_label, " (", format(Date, "%b %Y"), ")")) %>%
      dplyr::arrange(Date)
  })

  output$ci_event_selector <- renderUI({
    evs <- ci_events_available()
    if (nrow(evs) == 0)
      return(tags$p(style = "color:#718096;font-size:11px;padding:4px 0;",
                    "No events of this type for selected country."))
    selectInput("ci_selected_event", "Select event",
                choices = setNames(as.character(evs$Date), evs$label))
  })

  forecast_result <- reactive({
    req(input$country, input$forecast_metric, input$horizon)
    full_data <- Metrics %>% dplyr::filter(Survey.Country == input$country)
    tryCatch(
      suppressWarnings(fit_forecast(full_data, input$forecast_metric, input$horizon)),
      error = function(e) { message("Forecast ERROR: ", conditionMessage(e)); NULL }
    )
  })

  ci_result <- reactive({
    req(input$ci_selected_event, input$forecast_metric,
        input$ci_pre_months, input$ci_post_months)
    full_data  <- Metrics %>% dplyr::filter(Survey.Country == input$country)
    event_date <- as.Date(input$ci_selected_event)
    run_causal_impact(full_data, event_date, input$forecast_metric,
                      pre_months = input$ci_pre_months,
                      post_months = input$ci_post_months)
  })

  ci_has_error <- function(r) is.null(r) || (is.list(r) && !is.null(r$error))
  ci_error_msg <- function(r) {
    if (is.null(r)) "No result. Check sidebar selections." else r$error
  }

  make_trend_plot <- function(metric_col, title, ylab, show_slider = FALSE) {
    renderPlotly({
      md  <- metrics_filtered()
      evd <- events_filtered()

      p <- plot_ly(data = md, x = ~Date, y = ~.data[[metric_col]],
                   type = "bar", name = ylab,
                   marker = list(color = "rgba(0,105,148,0.75)"),
                   hovertemplate = paste0(
                     "<b>%{x|%b %Y}</b><br>", ylab, ": %{y:,}<extra></extra>")) %>%
        plotly::layout(
          title = list(text = title, font = list(size = 13)),
          xaxis = list(title = "", showgrid = FALSE,
                       rangeslider = list(visible = show_slider)),
          yaxis = list(title = ylab, showgrid = TRUE, gridcolor = "#e8e8e8"),
          plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc",
          bargap = 0.1, showlegend = TRUE,
          legend = list(orientation = "h", y = -0.2))

      if (nrow(evd) > 0) {
        max_val <- max(md[[metric_col]], na.rm = TRUE)
        if (is.na(max_val) || max_val == 0) max_val <- 1

        shapes <- lapply(seq_len(nrow(evd)), function(i) {
          list(type = "line",
               x0 = evd$Date[i], x1 = evd$Date[i],
               y0 = 0, y1 = 1, yref = "paper",
               line = list(color = event_colors[evd$event_type[i]],
                           width = 1.5, dash = "dot"))
        })

        for (etype in unique(evd$event_type)) {
          esub <- dplyr::filter(evd, event_type == etype) %>%
            dplyr::mutate(
              marker_y        = max_val * 0.97,
              # Sanitize label: remove curly braces which break plotly's
              # %{text} template interpolation
              safe_label      = gsub("[{}%]", "", event_label),
              hover_text      = paste0("<b>", event_type, "</b><br>",
                                       safe_label, "<br><i>",
                                       format(Date, "%b %Y"), "</i>")
            )
          p <- p %>% add_trace(
            data = esub, x = ~Date, y = ~marker_y,
            type = "scatter", mode = "markers", name = etype,
            marker = list(color = event_colors[etype], size = 9, symbol = "diamond"),
            text          = ~hover_text,
            hovertemplate = "%{text}<extra></extra>",
            showlegend    = TRUE)
        }
        p <- p %>% plotly::layout(shapes = shapes)
      }
      p
    })
  }

  output$p_internal <- make_trend_plot(
    "Downloads.Internal", "In-Country Downloads", "Downloads", show_slider = TRUE)
  output$p_statcomp <- make_trend_plot("STATCompiler", "STATCompiler Sessions", "Sessions")
  output$p_website  <- make_trend_plot("Website", "Website Visits", "Visits")
  output$p_sdr      <- make_trend_plot("Spatial.Data.Repository", "SDR Sessions", "Sessions")
  output$p_mobile   <- make_trend_plot("Mobile.App", "Mobile App Sessions", "Sessions")

  output$forecast_plot <- renderPlotly({
    tryCatch({
      result <- forecast_result()
      validate(need(!is.null(result),
        "Forecast requires 24+ months of non-zero data. Try Global or a higher-volume country."))
      fc       <- result$forecast %>% dplyr::mutate(Date = as.Date(ds))
      last_obs <- result$last_observed
      col      <- input$forecast_metric
      actuals  <- Metrics %>%
        dplyr::filter(Survey.Country == input$country, !is.na(.data[[col]])) %>%
        dplyr::transmute(Date, y = as.numeric(.data[[col]]))
      hist_fc   <- fc %>% dplyr::filter(Date <= last_obs)
      future_fc <- fc %>% dplyr::filter(Date >  last_obs)
      validate(need(nrow(future_fc) > 0, "No future periods — increase the forecast horizon."))

      plot_ly() %>%
        add_ribbons(data = future_fc, x = ~Date,
                    ymin = ~yhat_lower, ymax = ~yhat_upper,
                    fillcolor = "rgba(31,78,121,0.15)",
                    line = list(color = "transparent"), name = "80% CI") %>%
        add_bars(data = actuals, x = ~Date, y = ~y, name = "Actual",
                 marker = list(color = "rgba(0,105,148,0.7)"),
                 hovertemplate = "<b>%{x|%b %Y}</b><br>Actual: %{y:,}<extra></extra>") %>%
        add_lines(data = hist_fc, x = ~Date, y = ~yhat,
                  line = list(color = "rgba(31,78,121,0.4)", dash = "dot", width = 1.5),
                  name = "Model fit") %>%
        add_lines(data = future_fc, x = ~Date, y = ~yhat,
                  line = list(color = "#1F4E79", dash = "dash", width = 2),
                  name = "Forecast",
                  hovertemplate = "<b>%{x|%b %Y}</b><br>Forecast: %{y:,.0f}<extra></extra>") %>%
        plotly::layout(
          xaxis = list(title = "", showgrid = FALSE, rangeslider = list(visible = FALSE)),
          yaxis = list(title = col, showgrid = TRUE, gridcolor = "#e8e8e8"),
          plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc",
          legend = list(orientation = "h", y = -0.15))
    }, error = function(e) error_plot(paste("Error:", conditionMessage(e))))
  })

  output$impact_plot <- renderPlotly({
    tryCatch({
      col          <- input$forecast_metric
      full_metrics <- Metrics %>% dplyr::filter(Survey.Country == input$country)
      evd          <- events_filtered()
      validate(need(nrow(evd) > 0,
        "Select at least one event type in the sidebar to compute the event study."))
      study <- compute_event_study(full_metrics, evd, col, window_months = 6)
      validate(need(nrow(study) > 0,
        "Insufficient data for event study with this country / metric combination."))

      p <- plot_ly()
      for (etype in unique(study$event_type)) {
        sub    <- study %>% dplyr::filter(event_type == etype)
        n_max  <- max(sub$n_events, na.rm = TRUE)
        col_ev <- event_colors[etype]
        sub_ci <- sub %>% dplyr::filter(!is.na(ci_lo))
        if (nrow(sub_ci) > 0) {
          p <- p %>% add_ribbons(
            data = sub_ci, x = ~month_offset, ymin = ~ci_lo, ymax = ~ci_hi,
            fillcolor = paste0(substr(col_ev, 1, 7), "33"),
            line = list(color = "transparent"),
            name = paste0(etype, " 95% CI"), showlegend = FALSE, hoverinfo = "none")
        }
        p <- p %>% add_lines(
          data = sub, x = ~month_offset, y = ~avg_value,
          name = paste0(etype, " (n=", n_max, ")"),
          line = list(color = col_ev, width = 2.5),
          text = ~paste0(etype, "<br>Month: ", month_offset,
                         "<br>Avg: ", round(avg_value, 1)),
          hoverinfo = "text")
      }
      p %>%
        add_segments(x = 0, xend = 0,
                     y = min(study$avg_value, na.rm = TRUE),
                     yend = max(study$avg_value, na.rm = TRUE),
                     line = list(color = "#555", width = 1.5, dash = "dash"),
                     showlegend = FALSE, hoverinfo = "none") %>%
        plotly::layout(
          xaxis = list(title = "Months relative to event (0 = event month)",
                       showgrid = TRUE, gridcolor = "#e8e8e8",
                       tickmode = "linear", dtick = 1,
                       zeroline = TRUE, zerolinecolor = "#aaa"),
          yaxis = list(title = col, showgrid = TRUE, gridcolor = "#e8e8e8"),
          plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc",
          legend = list(orientation = "h", y = -0.3))
    }, error = function(e) error_plot(paste("Error:", conditionMessage(e))))
  })

  output$decomp_plot <- renderPlotly({
    tryCatch({
      result <- forecast_result()
      validate(need(!is.null(result), "Run a forecast first."))
      fc <- result$forecast %>% dplyr::mutate(Date = as.Date(ds))
      validate(need("yearly" %in% names(fc), "Yearly seasonality not available."))
      p1 <- plot_ly(fc, x = ~Date, y = ~trend, type = "scatter", mode = "lines",
                    line = list(color = "#1F4E79", width = 2), name = "Trend",
                    hovertemplate = "<b>%{x|%b %Y}</b><br>Trend: %{y:,.0f}<extra></extra>") %>%
        plotly::layout(yaxis = list(title = "Trend", showgrid = TRUE, gridcolor = "#e8e8e8"),
                       plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc")
      p2 <- plot_ly(fc, x = ~Date, y = ~yearly, type = "scatter", mode = "lines",
                    line = list(color = "#E67E22", width = 2), name = "Seasonality",
                    hovertemplate = "<b>%{x|%b %Y}</b><br>Seasonality: %{y:.3f}<extra></extra>") %>%
        plotly::layout(yaxis = list(title = "Seasonality", showgrid = TRUE, gridcolor = "#e8e8e8"),
                       plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc")
      plotly::subplot(p1, p2, nrows = 2, shareX = TRUE, titleY = TRUE,
                      heights = c(0.6, 0.4)) %>%
        plotly::layout(showlegend = TRUE, legend = list(orientation = "h"))
    }, error = function(e) error_plot(paste("Error:", conditionMessage(e))))
  })

  output$ci_main_plot <- renderPlotly({
    tryCatch({
      result <- ci_result()
      if (ci_has_error(result)) return(error_plot(ci_error_msg(result)))
      series      <- as.data.frame(result$series)
      series$Date <- as.POSIXct(rownames(series))
      event_date  <- as.POSIXct(as.Date(input$ci_selected_event))
      plot_ly(series) %>%
        add_ribbons(x = ~Date, ymin = ~point.pred.lower, ymax = ~point.pred.upper,
                    fillcolor = "rgba(39,128,185,0.15)",
                    line = list(color = "transparent"), name = "95% CI") %>%
        add_lines(x = ~Date, y = ~point.pred,
                  line = list(color = "#2980B9", dash = "dash", width = 2),
                  name = "Counterfactual") %>%
        add_lines(x = ~Date, y = ~response,
                  line = list(color = "#1F4E79", width = 2), name = "Observed",
                  hovertemplate = "<b>%{x|%b %Y}</b><br>Observed: %{y:,.1f}<extra></extra>") %>%
        add_segments(x = event_date, xend = event_date,
                     y = min(series$response, na.rm = TRUE),
                     yend = max(series$response, na.rm = TRUE),
                     line = list(color = "#E74C3C", width = 2, dash = "dot"),
                     name = "Event", showlegend = TRUE) %>%
        plotly::layout(
          xaxis = list(title = "", showgrid = FALSE),
          yaxis = list(title = input$forecast_metric, showgrid = TRUE, gridcolor = "#e8e8e8"),
          plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc",
          legend = list(orientation = "h", y = -0.15))
    }, error = function(e) error_plot(paste("Error:", conditionMessage(e))))
  })

  output$ci_summary_table <- renderTable({
    result <- ci_result()
    if (ci_has_error(result)) return(data.frame(Message = ci_error_msg(result)))
    s <- result$summary
    data.frame(
      Measure = c("Avg actual (post)", "Avg counterfactual",
                  "Absolute effect", "Relative effect",
                  "95% CI (lower)", "95% CI (upper)", "Posterior p-value"),
      Value   = c(round(s["Average","Actual"],          1),
                  round(s["Average","Pred"],            1),
                  round(s["Average","AbsEffect"],       1),
                  paste0(round(s["Average","RelEffect"] * 100, 1), "%"),
                  round(s["Average","AbsEffect.lower"], 1),
                  round(s["Average","AbsEffect.upper"], 1),
                  round(s["Average","p"],               3))
    )
  })

  output$ci_effect_plot <- renderPlotly({
    tryCatch({
      result <- ci_result()
      if (ci_has_error(result)) return(error_plot(ci_error_msg(result)))
      series      <- as.data.frame(result$series)
      series$Date <- as.POSIXct(rownames(series))
      event_date  <- as.POSIXct(as.Date(input$ci_selected_event))
      post        <- series %>% dplyr::filter(Date >= event_date)
      plot_ly(post) %>%
        add_ribbons(x = ~Date,
                    ymin = ~point.effect.lower, ymax = ~point.effect.upper,
                    fillcolor = "rgba(231,76,60,0.15)",
                    line = list(color = "transparent"), name = "95% CI") %>%
        add_lines(x = ~Date, y = ~point.effect,
                  line = list(color = "#E74C3C", width = 2), name = "Pointwise effect",
                  hovertemplate = "<b>%{x|%b %Y}</b><br>Effect: %{y:,.1f}<extra></extra>") %>%
        add_segments(x = min(post$Date), xend = max(post$Date),
                     y = 0, yend = 0,
                     line = list(color = "#555", width = 1, dash = "dot"),
                     showlegend = FALSE) %>%
        plotly::layout(
          xaxis = list(title = "", showgrid = FALSE),
          yaxis = list(title = "Estimated effect", showgrid = TRUE, gridcolor = "#e8e8e8"),
          plot_bgcolor = "#f8fafc", paper_bgcolor = "#f8fafc",
          legend = list(orientation = "h", y = -0.2))
    }, error = function(e) error_plot(paste("Error:", conditionMessage(e))))
  })
}

shinyApp(ui, server)
