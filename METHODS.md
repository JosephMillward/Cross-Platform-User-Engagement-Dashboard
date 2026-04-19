# Analytical Design Notes

## Overview

This document explains the methodological choices underlying the dashboard's
three analytical components: engagement trend visualisation, event study
design, and Bayesian causal inference via CausalImpact. It is written for a
technical audience familiar with applied statistics and program evaluation,
and is intended to accompany the portfolio as evidence of analytical
decision-making, not just implementation.

---

## 1. Engagement Trends

### Why separate Metrics and Events tables

Storing metrics and events in entirely separate long-format tables
and joining them only at render time in the plot layer ensures that masking from functions like `distinct()` would not occur and inadvertently only pull one event in months where multiple occurres. This means ten events on the same date produce ten independent vertical lines and ten hoverable markers in the dashboard,
each with their own label. 

### Event rendering: vertical lines vs. fixed-height dots

The users of this dashboard wanted to be able to see hover info, including the date and name of events. The solution was to use plotly `shapes` for the vertical lines (which span the full chart height regardless of scale) and separate scatter traces for the hoverable diamond markers, with `hovertemplate = "%{text}<extra></extra>"` to suppress the y-value from the descriptions.

---

## 2. Event Study Design

### What it measures

The event study computes the average platform engagement metric at each
monthly offset from -X to +X months relative to each event date, then
averages across all events of a given type for the selected country. The
output is a trajectory line per event type with the x-axis representing
months before and after the event.

This is directly analogous to the event study methodology used in financial
economics (Fama et al., 1969) and increasingly in program evaluation, often called 
a "distributed lag" or "dynamic treatment effects" specification.

### What it reveals that pre/post comparisons cannot

A single pre/post comparison collapses the temporal response into one number.
The event study reveals:

- **Response timing**: Is the lift immediate (month 0 spike) or delayed
  (ramp over months 1-3)? Delayed responses are common when the mechanism
  is word-of-mouth or captures follow-on data use rather than direct event attendance.
- **Response duration**: Does the lift persist, revert, or overshoot?
  Persistent lifts suggest durable behavior change, while rapid reversion suggests
  the event drove one-time curiosity rather than adoption.
- **Pre-trend**: Are there systematic differences in the months before the
  event? A rising pre-trend would suggest events are scheduled
  opportunistically after engagement is already growing, not causing growth.
  Flat pre-trends support a causal interpretation.

### Bootstrap confidence intervals

The 95% CI bands are constructed by resampling events with replacement
(n = 200 bootstrap iterations) and computing the 2.5th and 97.5th percentiles
of the bootstrap distribution of mean trajectories at each month offset.

**Key limitation:** For countries with fewer than 5 events of a given type,
the bootstrap CI is unreliable because a single influential event dominates
every resample. The `n=` count in the legend is the primary diagnostic
for interpreting CI width. Treat bands skeptically when n < 5. The Global
aggregate, which pools events across all countries, produces the most
statistically meaningful CIs.

### Handling clustered events

When multiple events of different types fall within the same month, each
event type's trajectory window includes the other events as concurrent
interventions. The event study design is more robust to this than CausalImpact
because the averaging process dilutes the influence of any single cluster:
a DHS publication that consistently co-occurs with dissemination events will
show a similar trajectory for both types, which is itself informative — it
suggests the two event types are operationally linked rather than independent.

For countries with very high event density (particularly in the Global
aggregate where all country-level events are pooled), interpret the event
study as estimating the average effect of a typical event *of that type*
in the context of the program's normal activity level, not the isolated
effect of that event type in the absence of all others.

---

## 3. CausalImpact: Bayesian Structural Time Series

### The fundamental problem it solves

Any before/after comparison of platform engagement around an event conflates
three things:

1. The causal effect of the event itself
2. The pre-existing trend (if downloads were already rising at 5%/month, a
   naive comparison attributes that growth to the event)
3. Seasonal patterns (a dissemination event in January will appear to "cause"
   a Q1 peak that was coming regardless)

CausalImpact addresses all three by fitting a state space model to the
pre-event period and projecting a *counterfactual* — the expected trajectory
in the absence of the event — which explicitly incorporates the estimated
trend and seasonal components. The causal effect is the difference between
the observed post-event series and this counterfactual.

### Why CausalImpact over standard interrupted time series (ITS)

Standard segmented regression ITS fits a parametric (usually linear) trend
to the pre-period and extrapolates it as the counterfactual. This works well
when:

- The pre-period trend is clearly linear
- The post-period is long enough to estimate a slope change reliably
- Seasonality is absent or already controlled for

For monthly program engagement data, none of these conditions reliably hold:

- Trend is non-linear: DHS platform adoption accelerated mid-series as the
  DHS mobile app and STATcompiler gained traction, producing a concave growth
  curve rather than a linear one
- Post-windows are often short (6-12 months) for events late in the data
  series, making slope change estimation underpowered
- Multiplicative Q1 seasonality (tied to publication release cycles) is
  strong enough to bias a linear counterfactual substantially if the
  event falls in a seasonal peak month

CausalImpact's local linear trend state space model captures a non-linear
trend from the pre-period without a parametric specification, and the
model's seasonal component is estimated jointly with the trend rather than
removed in preprocessing, which preserves the seasonal structure when
projecting the counterfactual forward.

### Model specification

The implementation uses the default CausalImpact configuration:

- **Local linear trend** with diffuse priors on level and slope variance,
  allowing the trend to evolve flexibly during the pre-period
- **Seasonal component**: not explicitly specified in the model (monthly
  data with short pre-windows does not reliably identify a seasonal component
  from the structural model alone); seasonal effects are captured implicitly
  through the trend's ability to fit seasonal patterns
- **MCMC samples**: 1000 (default), sufficient for stable posterior
  estimates with the series lengths encountered here

For production use with longer series (5+ years of pre-event data), adding
an explicit seasonal component would improve the counterfactual's accuracy
for events that fall in seasonally anomalous months.

### Interpreting the output

**Observed vs. Counterfactual chart**: The dashed blue line is the posterior
mean of the counterfactual; the shaded band is the 95% posterior credible
interval. The observed series falling consistently above the band in the
post-period is the visual signature of a positive causal effect.

**Effect Summary table**:

| Field | Interpretation |
|-------|----------------|
| Avg actual (post) | Mean observed metric value over the post-event window |
| Avg counterfactual | Mean model-predicted value if the event had not occurred |
| Absolute effect | Difference: actual minus counterfactual, per month |
| Relative effect | Absolute effect as a % of the counterfactual |
| 95% CI | Posterior credible interval on the absolute effect |
| Posterior p-value | Probability of observing an effect this extreme under the null; one-tailed |

**A note on the p-value and CI relationship**: The posterior p-value can be
below 0.05 even when the 95% CI marginally includes zero. This occurs, for example, when
the CI upper bound is close to zero (e.g., +0.9) but the posterior
distribution's mass is overwhelmingly on the negative side. The inverse can also be true: the CI lower bound may be close to zero (e.g., -0.3) while the posterior mass is overwhelmingly on the positive side, producing a p-value below 0.05 despite the interval marginally crossing zero. 
The p-value reports a one-tailed probability while the CI reports the 95% interval.
These answer related but distinct questions. When the CI crosses zero by more
than a trivial margin, treat the result as suggestive rather than conclusive
regardless of the p-value.

**Pointwise effect chart**: Shows the estimated causal effect at each
individual month in the post-window. This is useful for identifying
whether the effect is concentrated in specific months (consistent with a
discrete event) or spread evenly (consistent with a sustained program
change). A pattern of declining effect over the post-window is common and
expected, as direct event effects typically dimish over time.

### Pre-event window selection

The default 12-month pre-window is appropriate for most country/event
combinations. A general precaution is included below, as well as two edge cases require attention:

**Caution**: Given the nature of the program, there may likely be multiple events occurring over sequential months. In these cases, it is important to interpret the event date and pre/post windows closely. It would be fruitful to test the model with each proximate event date (e.g., test the model anchored on pub date in March, then MEL training in April, then dissemination event in May). Also, ensure that the outcome you are testing logically maps to the event selected (e.g., The report publication alone may not drive SDR session growth, but a targeted MEL/data use training likely would). Similar caution should be observed when selecting the time horizon for the pre and post-event windows. A 12-month window is ideal to capture seasonality in use (highly likely given programmatic and funding cycles, quarterly/annual reports, etc.), but this may lead to inclusion of other events that occurred which are not directly tied to the one that you are aiming to test. 

**Events early in the data series (pre-2015)**: The pre-window may overlap
with program ramp-up effects, when downloads and sessions were growing
rapidly as the platform launched. Including ramp-up in the pre-period
inflates the trend estimate and produces an aggressive counterfactual that
makes the event appear to have a *smaller* effect than it did. Consider
shortening the pre-window to 6-8 months for pre-2015 events.

**Events late in the data series (post-2021)**: The post-window is
truncated by the end of available data (March 2023 for the synthetic
dataset; the actual data end date in production). For events in 2022
or later, the 6-month default post-window may extend beyond the data,
producing a shorter-than-expected analysis window. The model handles
this gracefully but the summary statistics reflect the truncated window.

### Minimum data requirements

The `run_causal_impact()` function enforces three preconditions before
fitting the model, each returning a specific error message rather than
a silent failure:

1. At least 3 pre-event months of data (absolute minimum; 12 recommended)
2. At least 1 post-event month of data
3. At least 2 non-zero metric values in the pre-period

The third condition is the most commonly triggered for sparse countries.
If In-country Downloads is all zeros for the pre-window (common for
low-volume DHS countries), switching to STATCompiler Sessions or Website
Visits — which have sparser but more consistent coverage — typically
resolves the issue. The Global aggregate, which sums across all countries,
rarely fails this condition.

---

## 4. Prophet Forecasting

### Model choice rationale

Prophet (Taylor & Letham, 2018) is used rather than ARIMA for two reasons
specific to these data:

**Irregular spacing**: The Metrics table for sparse countries has genuine
gaps where no data was reported. ARIMA requires regular time series and
either imputation or a different specification to handle gaps. Prophet
handles irregularly-spaced data natively by operating on a continuous
time index rather than an array index.

**Automatic seasonality detection**: Prophet decomposes the series into
trend + seasonality + holidays components, fitting each independently.
The multiplicative seasonality mode (`seasonality.mode = "multiplicative"`)
is appropriate here because the amplitude of the Q1 peak scales with the
level of the trend — a country at 5,000 downloads/month has a proportionally
larger Q1 spike than one at 500 downloads/month.

### Hyperparameter choices

`changepoint.prior.scale = 0.05` (conservative). The default value of 0.05
in prophet is already conservative; it is kept here to prevent the trend
from overfitting to short-term fluctuations in the pre-period, which would
produce an implausible forecast. For the Global aggregate, which has a
smoother underlying trend, this setting produces well-behaved forecasts.
For sparse country series, the 24-month minimum data requirement serves as
the primary guard against overfitting.

### Forecast horizon

The 3-24 month range reflects a practical constraint: prophet's
multiplicative seasonality requires at least one full year of history to
estimate the seasonal component. Forecasts beyond 12 months for
country-level series should be treated as indicative rather than predictive
given the program-driven nature of engagement spikes (which are not
forecastable from historical patterns alone).

---

## 5. Synthetic Data Generation

The synthetic data generator (`data/generate_synthetic_data.R`) produces
engagement time series that preserve the following statistical properties
of real DHS program analytics data:

- **Monthly seasonality**: Peak Q1-Q2 (post-survey-release period),
  trough Q3-Q4, with a country-invariant seasonal factor applied
  multiplicatively so that larger countries have proportionally larger
  seasonal swings
- **Trend growth**: ~3% annual compound growth, reflecting gradual
  platform adoption, implemented as a cumulative multiplier over time
- **Country-level heterogeneity**: Base engagement levels span two
  orders of magnitude from high-volume (Kenya ~800 downloads/month) to
  sparse (Guinea ~55), reflecting the real DHS country portfolio
- **Zero-inflation**: Sparse countries (base < 100/month) have a 35%
  zero probability per month; mid-volume countries have a 15% rate.
  This produces the irregular sparse time series that stress-tests the
  CausalImpact minimum data checks
- **Metric correlation**: Downloads.External is derived from
  Downloads.Internal with log-normal noise, reflecting the real-world
  correlation between in-country and external dataset access
- **Event-anchored spikes**: 60% of synthetic program events are placed
  within 90 days of a real DHS publication date, with the remaining
  40% distributed randomly across the timeline

DHS publication dates are drawn from the live DHS API and are therefore
real, not synthetic. This ensures that the event study and CausalImpact
analyses have authentic temporal anchors even though the engagement data
are simulated.

---

## References

Brodersen, K.H., Gallusser, F., Koehler, J., Remy, N., Scott, S.L. (2015).
Inferring causal impact using Bayesian structural time-series models.
*Annals of Applied Statistics*, 9(1), 247-274.
https://doi.org/10.1214/14-AOAS788

Fama, E.F., Fisher, L., Jensen, M.C., Roll, R. (1969). The adjustment of
stock prices to new information. *International Economic Review*, 10(1), 1-21.

Scott, S.L., Varian, H.R. (2014). Predicting the present with Bayesian
structural time series. *International Journal of Mathematical Modelling and
Numerical Optimisation*, 5(1-2), 4-23.

Taylor, S.J., Letham, B. (2018). Forecasting at scale.
*The American Statistician*, 72(1), 37-45.
https://doi.org/10.1080/00031305.2017.1380080
