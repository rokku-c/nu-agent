# apps/financial — design

Scope: **markets, investments, money, the economy, and simulation.** Analysis and
simulation only. This is not a personal bookkeeping tool — no receipts, no
budgets, no bill splitting. What it is: a research instrument.

The repository's one rule applies here with more force than anywhere else:

> **The model writes code and explains. It never produces a number.**

A tool-calling agent that invents a plausible Sharpe ratio is worse than no agent
at all, because the number is *checkable-looking* and *wrong*. Every figure this
app produces comes from the kernel, and carries its provenance.

And the second rule, which is specific to this domain:

> **Nothing enters the kernel without knowing when it was known.**

---

## 0. Principles

**Three clocks.** Every financial datum involves three distinct times: the period
it *refers* to, the moment it was *published*, and the moment you are *looking at
it*. Collapsing them is the single most common way to build a system that is
confidently wrong.

**Point-in-time (PIT) or it is fiction.** Financial statements are restated.
Macro data is revised, and arrives after its reference period. Index membership
changes. Prices are adjusted for corporate actions. A backtest or a study that
uses today's data to explain the past is not measuring what it claims to measure.

So a datum in this system is never `{value}`. It is:

```
{ value, reference_period, published_at, vintage, source, units, definition }
```

That is the first-class record. Everything downstream depends on it.

**Every number carries its definition.** Finance has ten definitions of every
word. Return (simple / log / time-weighted / money-weighted / pre-tax / post-tax /
nominal / real). Volatility (which annualization factor?). Drawdown (which one?).
VaR (which confidence, which horizon, which method?). A number without its
definition is not a number. The kernel should make the definition *attached*, not
documented elsewhere.

**Reproducibility is a hash.** A result is `(data snapshot, code revision,
parameters)`. If it can't be recomputed to the same digits, it isn't a result.

**Macro is not the market.** Growth is not equity returns. Inflation is not rates.
Rates are not the currency. Each of these pairs is *related*, and each of them can
move in opposite directions for years. The system must be able to *test* these
relationships, not narrate them.

---

## I. Data

The most expensive layer, and the one that cannot be bought with cleverness.

| Class | Contents | The real difficulty |
|---|---|---|
| Prices | daily / minute / tick, order book, volume | corporate actions, calendars, timezones, DST |
| Fundamentals | three statements, share count, dividends | PIT; restatements; footnotes |
| Macro | GDP, CPI, rates, money, employment, trade | release calendar, revisions, reference ≠ release |
| FX & rates | spot / forward / swap, yield curves | quotation conventions, value dates |
| Derivatives | option chains, IV surface, futures term structure | greeks, expiries, settlement rules |
| Alternative | positioning, flows, sentiment, satellite, supply chain | coverage bias, survivorship |

**Trading calendars and timezones are first-class.** Markets close on different
days. DST switches on different dates. Cross-country and cross-asset work that
ignores this is wrong — quietly, and in ways that survive review.

**Data quality is reported, never swallowed.** Missing values, outliers, look-ahead
leakage, misaligned timestamps, unit errors (yuan vs. ten-thousand yuan), broken
adjustment factors. Each defect should be *detectable and surfaced*, because a
silently-repaired series produces a silently-wrong conclusion.

**Vintage snapshots.** Every pull is stored as an immutable snapshot with a
timestamp. This is the physical substrate of reproducibility, and the only way to
evaluate a forecast honestly (see §VII).

**Source tiers.** Free (FRED, World Bank, IMF, national statistics offices),
broker feeds, paid terminals (Bloomberg, Refinitiv, WRDS), self-built. Licensing
and redistribution limits belong in the design, not in a lawyer's memo later.

**Transcription — for the sources that have no API.** A large part of what matters
has no endpoint: a statistics bureau's release page, a central bank statement, a
PDF table, a scanned filing. The model is the right tool for this, and the line
that makes it safe is **extraction is not generation**:

- The model does not *compute* a number; it *transcribes* one it can see. That is
  checkable, which generation is not.
- The target shape is a **fixed schema**, handed to the model as the provider's
  structured-output format (`output_format` / `response_format`) rather than
  requested in a prompt — `tools/jsonschema.nu` already exists to produce one.
- **The evidence is a required parameter.** A recorded transcription carries the
  source URL and the verbatim excerpt beside the value. A number whose source text
  is missing cannot be checked, and an unchecked number from a model is
  indistinguishable from an invented one — so the tool refuses to record it.
- The record that comes out is **the same shape** as one fetched from an API:
  `{value, reference_period, vintage, units, source}`. Nothing downstream can tell,
  or needs to, which door a datum came in through.

This is what keeps §I from being a list of APIs: the sources with an API get a
parser, the sources without one get transcription, and both land in the same store.

---

## II. Compute kernel

Deterministic, pure, schema'd, testable. Shaped like `tools/calc.nu`: the kernel
is the thing that produces numbers, so it must be the thing with no model in it.

- **Returns**: simple/log, period alignment, annualization, cross-currency
- **Statistics**: moments, quantiles, rolling windows, autocorrelation, stationarity
- **Risk**: volatility (multi-definition), the drawdown family (MDD, duration,
  Calmar), VaR/CVaR (historical/parametric/Monte Carlo), tails, concentration, liquidity
- **Correlation**: must be time-varying, and must account for **convergence in
  crises**. A static correlation matrix is the most dangerous simplification in
  finance, because it fails exactly when it is needed. (See §VII, copulas.)
- **Performance**: Sharpe/Sortino/information ratio, **TWR and MWR kept separate**
  (conflating them systematically overstates skill), attribution
- **Factors**: CAPM → Fama-French → multi-factor → risk models; exposures,
  loadings, pure factor returns
- **Valuation**: DCF, DDM, residual income, relative multiples, option pricing
- **Optimization**: mean-variance, risk parity, Black-Litterman, constrained convex,
  cost-aware; robust and resampled variants

**Attribution is the point.** Where did the return come from — beta, factor
exposure, sector, selection, timing, currency, leverage? Without attribution, a
performance number is just a number.

---

## III. Investments

- **Portfolio construction**: weights, constraints, rebalancing policy, tax lots
- **The two return conventions**: TWR for evaluating a strategy, MWR/IRR for
  evaluating *your* experience of it. They differ, and the difference is real money.
- **Risk models**: factor covariance, specific risk, stress betas
- **Performance attribution**: Brinson (allocation/selection), factor-based, risk-based
- **Rebalancing & execution**: corridors, calendar vs. threshold, T-costs, capacity
- **Derivatives**: pricing, greeks, surface construction, term structure
- **Positions vs. flows**: market value and cost basis are *different series*. Mixing
  them contaminates both return and exposure analysis.

---

## IV. Money & international finance

Its own grammar:

- **Rates**: spot / forward / swap, swap points, quotation conventions (direct vs.
  indirect quoting — trivially easy to invert, and it destroys everything downstream)
- **Parity relations**: covered and uncovered interest parity, purchasing power
  parity, real effective exchange rates
- **Factors**: carry, momentum, value, the dollar smile
- **Policy**: rate paths, central bank reaction functions, balance sheets, QE/QT
- **Monetary aggregates**: M0/M1/M2, credit impulse
- **Regimes**: floating, managed, crawling peg, currency board, dollarization; capital
  controls; the trilemma as a hard constraint
- **Risk**: currency crises, external debt, reserve adequacy, the balance of payments
- **Digital**: stablecoins, CBDC (retail vs. wholesale)

**The cross-currency trap**: a multi-country portfolio is two *different strategies*
depending on whether it is currency-hedged, and the hedging cost is the other side
of carry. The hedge decision is explicit, never implicit.

---

## V. Macro & the economy

The goal is not to forecast macro. The goal is to **locate and explain**.

- Release calendar + vintage revisions + surprise indices (actual vs. expected)
- Indicator classification: leading / coincident / lagging; where are we in the cycle
- Inflation decomposition: core/headline, goods/services, wages, expectations
- Employment, output gap, capacity utilization, credit conditions
- Policy analysis: fiscal, monetary, regulatory — and the **transmission mechanism**
- Nowcasting (high-frequency data onto the current quarter)
- Cross-country comparison, where the hard part is *definitional harmonization*

And the discipline that keeps this honest, restated because it is so often violated:
**macro ≠ markets.** Every claimed link between an economic variable and an asset
price is a hypothesis to be tested against data, not a sentence to be written.

---

## VI. Policy & the monetary toolkit

This is a core module, not decoration. Policy is where asset prices start: the rate
path sets the discount rate, the balance sheet sets liquidity, the exchange-rate
regime sets a country's degrees of freedom. It is also where narrative runs
wildest — which is precisely why it must be data.

### The toolkit, in full

Most people know "rate hikes." The complete set is seven families:

**1. Price**
- The policy rate — but this is **never a single number, it is a system**: the
  operative rate + a corridor (ceiling = lending facility, floor = deposit
  facility / reserve remuneration) + corridor width.
- Yield curve control — targeting a specific tenor (Japan 2016–2024; Australia
  2020–2021, abandoned as a failure)
- Negative rates (ECB, Japan, Switzerland, Sweden historically; Denmark as a
  currency-peg defense)
- The zero / effective lower bound

**2. Quantity**
- Open market operations (repo / reverse repo, term facilities)
- Reserves: the reserve requirement ratio (a *primary* tool in China, and tiered),
  interest on reserves
- QE: government bonds, MBS, corporate credit, **equity ETFs (Bank of Japan)**
- QT: passive runoff vs. active sales, and the pace cap
- Lending / discount facilities: standing facilities, swap lines

**3. Credit & macroprudential**
- Loan-to-value, debt-service-to-income, stressed underwriting floors
- Countercyclical and systemic capital buffers
- Sector concentration caps (China's property loan concentration regime)
- Window guidance / moral suasion
- Targeted facilities: TLTRO (ECB), Funding for Lending (BoE), targeted RRR cuts (PBoC)

**4. Communication**
- Forward guidance: **time-contingent vs. state-contingent** ("until inflation
  reaches 2%")
- Dot plots, projections, minutes, press conferences
- The framework itself: inflation targeting / dual mandate / multi-objective;
  average inflation targeting and its introduction *and* abandonment
- This is the one family where **the tool *is* language**. Handled in §VI.b.

**5. FX**
- Intervention: sterilized vs. unsterilized, verbal vs. actual
- Regimes: float / managed float / crawling peg / currency board (Hong Kong) /
  dollarization
- Capital controls, reserve management, central bank swap lines (Fed lines, regional
  arrangements such as CMIM)
- The trilemma is the binding constraint here

**6. Crisis**
- Lender of last resort, liquidity facilities
- Direct lending facilities (to SMEs, municipalities)
- Anti-fragmentation tools (the ECB's TPI — aimed squarely at sovereign spreads)
- CBDC, yield caps

**7. Structural & the fiscal-monetary interface**
- Structural monetary tools (carbon-reduction, tech-innovation, housing relending)
- Central bank remittances; the Treasury General Account and its liquidity effects
- The degree of deficit monetization — which decides the fate of many emerging markets

### VI.a The institutional map

| Body | Objective | Decision mechanics |
|---|---|---|
| Federal Reserve | dual mandate | 8 meetings/yr, dot plot, SEP; IORB + ON RRP corridor |
| ECB | price stability (HICP) | three rates; the **operative rate moved from the refi rate to the deposit facility rate**; TPI |
| PBoC | multi-objective | **dual pillar** (monetary + macroprudential); quantity and price together; has changed its own operative rate (the LPR is a *quoted* rate, not the policy rate); window guidance |
| Bank of Japan | 2% inflation | long YCC, negative rates, equity ETF purchases; exited in 2024 |
| Bank of England | 2% CPI | APF; **active** QT (outright sales) |
| SNB | price stability + FX | intervention is the primary tool; very large reserves |
| BoC / RBA / RBNZ | inflation targeting | corridor systems; the RBA's YCC is a textbook failure case |
| Emerging markets | wildly heterogeneous | Brazil (inflation targeting, aggressive); India (repo + corridor); Turkey (a live specimen of political rate interference) |
| Regional bodies | — | CMIM (ASEAN+3), BCEAO, ECCB |
| International | — | IMF (SDR, Article IV), BIS (Basel, global liquidity), FSB |

### VI.b Modelling policy — the actual design work

**① The policy rate is a system, not a scalar.** Store the operative rate, the
corridor bounds, and — critically — **regime breakpoints**. Every major central
bank has switched its operative rate: the ECB from refi to deposit facility, China
from administered lending/deposit rates to the 7-day reverse repo. **The
institution's mechanics change, which makes policy data PIT data.** Unmarked
breakpoints make the whole history incomparable.

**② The shape of an action.** Body / instrument family / action / parameters
(magnitude, target range, tenor, size, conditions) / decision time / effective
time / **vote** (material for the Fed and BoE) / language / expectation comparison.

**③ Language is a time series.** Store full statements and **diff them**. The first
signal of a turn is usually in the wording, not the number. This is one of the
model's most legitimate uses: comparing two statements, tracking how the phrase
"data dependent" evolves. Store the text; let the model read it; keep it out of the
numeric path.

**④ Actual vs. expected.** The *surprise* moves markets more than the action. Store
market-implied paths (OIS forwards, rate futures), analyst expectations, dot plots.
The object of analysis is `actual − expected`.

**⑤ The transmission chain, traced.**
`policy rate → money market rate → bank lending rate → bonds → FX → asset prices → real economy`

And **the chain differs by country**: China has the LPR as an intermediate link,
the euro area has sovereign spreads and fragmentation, the US has money markets and
the GSEs. One transmission model applied to all countries will be wrong.

**⑥ The fiscal-monetary interface.** Who buys the government's debt, and where the
central bank's boundary with the treasury sits. This is the origin of many emerging
market crises, and it is a live variable in developed markets too.

### VI.c Cross-country comparability — the hard part

"25bp hike" is **not comparable** between the Fed and the PBoC:

- China uses the 7-day reverse repo, moves in 10bp steps, and moves quantity at the
  same time
- The Fed uses a target range, typically in 25bp steps
- Some central banks work through the exchange rate instead

Comparability therefore requires **constructed stance measures**, not raw rates:

- **Shadow rates** (to pass through the lower bound)
- **Taylor rule gaps** (actual minus rule-implied)
- **Real policy rates** (nominal minus inflation) — the true starting point for
  cross-country comparison
- Monetary policy surprise indices
- Central bank balance sheet / GDP

Plus two first-class fields: **the exchange-rate regime** (which sets degrees of
freedom) and **the mandate and independence** (which set the reaction function).
Without these, "why did this central bank do that" is unanswerable.

### VI.d Analysis dimensions

Stance (via the constructed measures above) · cycle identification and amplitude ·
remaining space (distance to the bound, reserves, fiscal room) · transmission
elasticity, compared across countries · spillovers and divergence (US tightening,
the dollar cycle, rate differentials → FX → carry) · credibility and expectation
anchoring · evaluation of unconventional policy and its exit costs.

### VI.e Boundaries

Central banks are *deliberately* vague ("data dependent"). The model must not
convert vagueness into false certainty — an interpretation is labelled as an
interpretation. Regime breakpoints must be marked or all long-horizon analysis
breaks. And a policy stance, as understood at the time, differs from the same
stance read in hindsight: PIT, again.

---

## VII. Simulation

### VII.0 "Simulate" means at least eight different things

They use different mathematics, different measures, and different credibility
standards. The system keeps them apart, because merging them is how a hedonic model
of option pricing ends up quietly informing a stress test.

1. **Pricing** — options (BS / binomial / Monte Carlo / finite difference), rate
   models (Hull-White, LMM), credit models
2. **Path simulation** — GBM, jump-diffusion, stochastic volatility (Heston), copulas;
   whole forward curves moving together
3. **Backtesting** — a strategy replayed over history (§VIII)
4. **Portfolio simulation** — weights + rebalancing rules + constraints → paths,
   with costs and taxes
5. **Scenarios & stress** — historical (2008, 2020, 2015), hypothetical (rates +300bp),
   and **reverse stress testing** (what has to happen for me to blow up)
6. **Optimization** — mean-variance, risk parity, stochastic programming, optimal execution
7. **Economic models** — DSGE, input-output, agent-based, microstructure, contagion
8. **Assumption exploration** — sensitivity, tornado charts, uncertainty decomposition

### VII.1 The three measure traps

Each must be declared, because each silently invalidates results when it isn't:

- **Risk-neutral vs. physical measure.** Pricing uses risk-neutral; risk management
  uses the physical measure. Mixing them is a serious error, not a style choice.
- **No-arbitrage vs. equilibrium.** Two different paradigms with different assumptions.
- **Nominal vs. real.** Whether inflation adjustment is applied.

### VII.2 Macro forecasting — the unified form

Nearly all macro forecasting reduces to a **state-space** model:

```
observation:  y_t = Z α_t + d + ε_t
state:        α_t = T α_{t-1} + c + R η_t
```

This single form subsumes dynamic factor models (DFM), VARMA, unobserved-components
models, mixed-frequency nowcasting, time-varying parameters, and stochastic
volatility. Its practical virtue: the **Kalman filter handles ragged edges and
missing data natively**, which is exactly the shape of macro data — series with
different publication lags, arriving continuously.

The estimator is **Bayesian**, and this is not a fashion. Macro series have a few
hundred observations and dozens of parameters. Priors are not a preference here,
they are the only thing standing between you and an overfit model. And the posterior
gives you the predictive *distribution* for free, which is the only honest output.

**The workhorse ladder**, roughly in order of how much value they deliver per unit
of effort:

1. **Bridge equations** — regress the quarterly target on monthly indicators. The
   basis of GDPNow-style nowcasts.
2. **Dynamic factor models** — dimensionality reduction + Kalman. The NY Fed nowcast.
3. **MIDAS** — mixed-frequency sampling regression.
4. **BVAR** — the workhorse for macro forecasting. Minnesota priors, Gibbs sampling,
   and impulse response functions. **This is the 90% solution.** Start here.
5. **Local projections** (Jordà) — regression-based IRFs; more robust than VAR to
   misspecification.
6. **TVP-VAR / stochastic volatility** — when parameters drift and shocks are
   heteroskedastic, which they always are.
7. **FAVAR** — when there are more variables than observations.
8. **DSGE** — for structural *interpretation*, not for forecasting. Log-linearize,
   solve via Blanchard-Kahn / generalized Schur, estimate by Bayesian methods.
   Dynare's world.
9. **Machine learning** — LASSO, random forests, gradient boosting, neural nets.
   The FRED-MD benchmark literature is unambiguous: **the gains are modest and
   horizon-specific**, because the binding constraint is sample size, not model
   capacity. Do not reach for a deep net on 300 observations. It will lose to a BVAR
   and it will lose invisibly.
10. **Agent-based / network** — heterogeneous agents, emergence, contagion.

### VII.3 The simulation pipeline

```
posterior p(θ | data)   --MCMC / variational inference-->
        │
        sample θ⁽¹…ˢ⁾
        │
        for each θ⁽ˢ⁾: propagate y⁽ˢ⁾_{T+1…T+H}   (shocks + parameter uncertainty)
        │
        predictive distribution {y⁽ˢ⁾}
        │
        quantile bands · densities · probabilities ("recession probability")
```

Both uncertainty sources must be propagated. Reporting shock uncertainty while
holding parameters fixed at their posterior mean produces bands that are too
narrow, systematically, and in the direction that makes a forecast look better
than it is.

### VII.4 Conditional forecasting — the policy instrument

The most valuable output for policy analysis is not "what will happen" but "what
follows *if*":

- **Linear models have a closed form.** Joint normality gives the conditional mean
  and variance of the remaining variables given a path for some of them.
- **Nonlinear models** use forecast-condition iteration (Waggoner-Zha) or simulation
  with rejection sampling.

This is the query "if the policy rate goes to 5%, what is the inflation path" —
and it is where a macro simulation system earns its keep.

### VII.5 Three things every output must carry

1. **A distribution, not a point.** A point forecast is a lie of omission.
2. **An uncertainty decomposition** — shocks vs. parameters vs. model. Which of the
   three dominates determines whether more data or a better model would help.
3. **Real-time evaluation.** Forecast accuracy must be judged against **the vintage
   that was available at the time**. Scoring with revised data is the macro analogue
   of look-ahead bias in a backtest, and it is the most common way this literature
   fools itself. The vintage store in §I is what makes this possible.

### VII.6 The compute decision — and where Burn actually belongs

There is a real question here, and the honest answer is more specific than "use Burn
for matrix math."

**Three tiers:**

| Tier | Workload | Right tool |
|---|---|---|
| Deterministic small-matrix linear algebra | Kalman filter (small state), VAR OLS/Gibbs, Cholesky, eigendecomposition, generalized Schur (Blanchard-Kahn), optimization | **faer** or **nalgebra** |
| Gradient-based | Neural nowcasting, variational inference, Bayesian neural nets, differentiable state space, higher-order perturbation of DSGE | **Burn** (autodiff) |
| Large-scale parallel / GPU | Sign-restricted VAR (10⁴–10⁵ accepted draws), Monte Carlo at 10⁵–10⁷ paths, particle filters with many particles, many-chain MCMC | **Burn** (wgpu / CUDA) |

The judgement: **Burn's value is gradients and scale, not matrix arithmetic.** Using
it to multiply two 5×5 matrices is both slower (dispatch and graph overhead) and more
code than `nalgebra`. Reserve it for where it is the only reasonable option.

Two further cautions, both learned from how these projects actually go wrong:

- **MCMC is usually not matmul-bound.** It is bound by the number of draws and the
  cost of a likelihood evaluation. A GPU helps far less than intuition suggests
  unless the model itself is large. Measure before porting.
- **Do not mix tensor types per-operation.** Pick the boundary at the module level —
  `faer` for the deterministic kernel, `Burn` for the gradient/scale kernel — and
  convert at the seam via slices.

**Burn, as of 0.22 (September 2026)** — the details matter because the API moved:

- Models no longer carry a `Backend` generic: `Tensor<B, 2>` became `Tensor<2>`, and
  execution location is chosen by `Device`. Recompilation after a model edit dropped
  from ~15s to ~1s in their benchmarks.
- Backends: CUDA, ROCm, Metal, Vulkan, WebGPU via the CubeCL/CubeK kernel layer
  (introduced in 0.20).
- **`ndarray` and LibTorch backends are deprecated** in 0.22; the pure-Rust CPU path
  is now **Flex**. The Candle backend was removed.
- Selected at runtime: `Device::flex()`, `Device::wgpu(...)`, `Device::cuda(0)`.

### VII.7 Traps

- **Evaluating with revised data.** The cardinal sin (§VII.5).
- **Small samples + deep learning.** 300 observations will not support a network.
- **Structural breaks.** 2008, 2020, and every regime change make parameters unstable
  in ways that a constant-parameter model hides.
- **Variable selection.** More variables → parameter explosion → factors or priors,
  not more regressors.
- **Causal claims.** Impulse responses are conditional on an *identification
  assumption* (Cholesky, sign restrictions, external instruments, narrative). The
  assumption must be declared with every IRF. An unidentified IRF is a drawing.
- **Over-engineering.** BVAR, DFM, and local projections deliver most of the value.
  Reach for DSGE and neural nets only when there is a specific question they answer.

---

## VIII. Backtesting

Its own section, because self-deception here is systematic rather than incidental.

**Biases that must be handled, not noted:**

- **Look-ahead** — using information unavailable at the time. PIT data is the only cure.
- **Survivorship** — testing only the instruments that survived.
- **Data snooping / p-hacking / multiple testing** — test N strategies across M
  parameter sets and something is "significant." Report *how many* were tried;
  deflated Sharpe.
- **Overfitting** — walk-forward / rolling validation; a genuine out-of-sample holdout.
- **Costs** — commissions, slippage, market impact, capacity. **A strategy return
  that ignores costs is fictional.**
- **Executability** — borrow availability, short constraints, price limits, halts,
  lot sizes, settlement.
- **Execution assumptions** — signal at close, fill at next open? This one assumption
  decides outcomes.
- **Parameter sensitivity** — a strategy that dies on a small parameter nudge is noise.

**The criterion**: a backtest is credible not because its Sharpe is high, but because
**it survives across many defensible specifications**. The system should run that
sweep automatically rather than letting a human pick the flattering configuration.

---

## IX. Research & reproducibility

- **Experiment tracking**: every study is `(data snapshot, code revision, parameters)`
  with a unique id
- **Recomputable**: anyone — including you in three months — reproduces the identical
  numbers in one command
- **Hypothesis → test → record → archive**, *including the failures*. A rejected
  hypothesis that isn't written down gets re-tested forever.
- Research records, not scattered scripts

---

## X. The assistant

This domain has the lowest tolerance for hallucination of any we could pick, because
**post-hoc narrative is trivially easy to fabricate and very hard to detect.** The
model's placement is therefore narrow and specific.

**Should do:** natural-language entry (translating a question into a query or a
script) · **write code** — which the deterministic engine then executes · explain
results · retrieve (filings, footnotes, statements, policy documents, literature) ·
propose hypotheses · find contradictions · point out that a conclusion is
under-evidenced · **adversarially audit your backtest assumptions**.

**Must not do:** produce any number (price, return, probability, forecast) · emit
"it will rise / fall" judgements · substitute narrative for evidence — a chain like
"because the Fed…, therefore…" must have every link pointing at data, or it is
prose.

**Boundaries:** a research instrument, not an investment adviser. No personalized
recommendations, no discretionary decisions. Every output carries uncertainty.

**Subagent roles**: data-quality checker · **backtest auditor** (whose only job is
to hunt biases) · literature researcher · code reviewer. Each narrow, none producing
numbers.

---

## XI. Trust & correctness

- **Invariants** (constraint-level, not advisory): adjustment factors consistent,
  portfolio weights sum to one, no PIT leakage, balance and flow conservation
- **Data lineage**: every number traces to source data, transformation chain, and
  code revision
- **Definitions travel with numbers**
- **Sandboxing and quotas**: backtests and Monte Carlo are expensive; budget them
- **Legality**: data licensing, scraping boundaries, redistribution limits
- **Local-first**: strategies and research are among the highest-value private data
  a person holds. Default is that they do not leave the machine.

---

## XII. Architecture

### The container question

nu-agent is pure nushell. A numeric kernel is not. That is a real architectural
commitment, and there are three ways to make it, with different costs:

| Option | How | Cost |
|---|---|---|
| **nushell plugin** (Rust) | `nu-plugin` crate; commands register natively | adds a Rust toolchain to the repo; needs a build step |
| **MCP server** | expose the kernel as a separate MCP process | another protocol hop; nu-agent's MCP support is currently server-side |
| **pure nu** | implement in nushell | fine for OLS on small data; not viable for Kalman, MCMC, or anything at scale |

**Recommendation: the nushell plugin.** The reason is structural rather than
performance. A plugin command has a **signature**, and `core/expose.nu` turns
signatures into tool schemas automatically. So the agent gets `macro forecast` and
`mc simulate` as first-class, schema'd tools *for free* — and, crucially, gets
**those** rather than `bash`. That is the repository's one rule, satisfied by
construction: the agent sees capabilities, not the host.

The plugin is also a **persistent process**, which matters when a command needs a
loaded dataset rather than a cold start.

Note the prerequisite: **this machine currently has nushell 0.116.0 and no Rust
toolchain.** Adding one is the first real decision to make, and it should be made
deliberately rather than as a side effect of writing a Kalman filter.

### Shape

```
nushell  (host · orchestration · the agent)
   │  expose from-module  →  tool schemas, automatic
   ▼
nu_plugin_finance  (Rust)
   ├── faer / nalgebra   deterministic linalg: Kalman, VAR, optimization, decompositions
   ├── Burn 0.22         gradients & scale: NN, VI, large MC/MCMC, particle filters
   └── data layer        PIT · vintage · calendars · quality reporting
```

### Mapping onto nu-agent's existing primitives

| Capability | Lands on |
|---|---|
| Compute primitives (returns, risk, attribution, pricing) | `apps/financial` tool layer — pure + schema'd, shaped like `calc` |
| Data access | narrow tools `market query` / `macro query` / `pit get` — **not** `bash` / `nu-shell` |
| Long jobs (backtests, Monte Carlo) | subagents, `core/task.nu` — already a nested loop in a child process; narrows capability, never widens it |
| Resumable research | `core/session.nu` — one study is one session |
| Keeping large datasets out of context | `core/context.nu` folding + on-demand queries |
| Write/export denied by default | `core/policy.nu` |
| Local model for data, remote model for reasoning | `core/provider.nu`, both dialects |
| Backtest auditor · data-quality checker | subagents — narrow, no numbers |

---

## XIII. The daily loop

Everything above is machinery. This is the routine it serves, and it is the test of
whether the machinery is real: **every step has to be evaluable the next day, or it is
decoration.**

```
  拉取 (cached) → 状态 → 预测 → 对比昨日 → 行动/观察 → 归档 → 评估
       ↑                                                      │
       └────────────────────── 次日 ───────────────────────────┘
```

### Predictions are append-only

The most important rule in this chapter, and the one nearly everyone gets wrong:

> **A prediction is a record carrying the moment it was made. Making a new one never
> changes an old one.**

"次日修订预测" means the revision is written *beside* yesterday's, not over it. Overwriting
destroys the only thing that says whether any of this works: what you believed at a time
when you could not yet know. This is §0's three clocks pointed at the output instead of the
input — a system that revises its own history cannot be scored, and an unscorable forecaster
is a conversation, not an instrument.

So a stored prediction carries `{made_at, as_of, horizon, subject, value, distribution,
assumptions, inputs}` — and `inputs` is a list of `{source, url, fetched_at}`, so the
question "what did you know when you said that" has an answer (§I's archive is what makes
that list reconstructible).

### Evaluation is the product

Not the forecast. A forecast nobody scores is a mood. The daily loop therefore files, for
every past prediction, what actually happened — and the interesting output is not the hit
rate but the *calibration*: when the system says 70%, is it right 70% of the time, at each
horizon, for each kind of subject? That number is the only honest summary of the whole
apparatus, and it takes months of archived predictions to earn.

### The layers, and what each still needs

| Layer | Needs | Have |
|---|---|---|
| Data | markets, filings, positioning | macro only (§I) |
| Facts | PIT records → aligned frames | §I, and `frame`/`state` |
| Analysis | levels, spreads, factors, correlation | the series kernel (§II) |
| Models | VAR / conditional forecast, factor models | nothing |
| Views | versioned predictions + distributions | nothing |
| Actions | signals, scheduled rules, triggers | nothing — **and see below** |
| Archive | everything, indexed | the fetch store; sessions and traces |

### Actions are not views

"At this node, at this price, buy" is an *instruction*. A forecast is an *opinion*. They live
in separate modules and separate namespaces, because a system that blurs them lets a model's
opinion be executed as an order. The action layer takes signals that were defined in advance,
including the conditions under which they do nothing.

### Transmission chains, not correlation searches

A question like "will the BoJ's last move affect Chinese equities, and where" is not answered
by scanning for correlation — that finds whatever happened to co-move. It is answered by
writing down an explicit chain and testing each link:

```
BoJ hikes → yen carry unwinds → global risk appetite → northbound flows / risk premia
          → A-share sectors with the most foreign and duration-sensitive ownership
```

Every link is a claim that can be checked against data or falsified, and a chain whose links
are untestable is a story. This is the shape the assistant should produce — and the reason it
must not produce the numbers itself: the chain is the model's job, the measurement is the
kernel's.

### Market-specific constraints are not details

A backtest that ignores the market's plumbing is fiction, and in A-shares the plumbing is
unusually load-bearing: T+1 settlement, price limits, the stamp duty, short-sale scarcity,
trading halts, and index-inclusion effects. "底仓 + T+0" is a real strategy there and it is
*defined* by the T+1 rule; a backtest that does not model T+1 is not measuring that strategy.
The US curve, CNH, and A-shares also trade on different calendars and in different sessions,
which is why §I insists calendars and timezones are first-class.

---

## In one line

> **The completeness of this system = point-in-time data + definition-carrying
> deterministic computation + simulation that declares its measure and reports its
> uncertainty + an assistant that writes code and explains, and never produces a
> number.** Remove any one, and the other three degrade into storytelling.
