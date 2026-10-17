# BalatroMultiBots

Practice bots for Balatro Multiplayer.

## Experimental Multiplayer private lobbies

With `BalatroMultiplayerExperimental-dev`, a private-lobby host gets an
**Add Bot** button in the lobby action row. Configure the bot and choose
**Add Bot to Lobby**. Repeat to add more bots; each bot uses its own network
connection and simulation, so practical count depends on the host PC. Everyone
sees a lobby warning while bots are active. Duplicate bot names receive numeric
suffixes; distinct names remain unchanged.

Bot players carry a **BOT** tag in player lists. Spectating a bot is allowed, but
currently shows an unavailable message instead of gameplay. Each bot gets a
deterministic peer-specific seed so bot-vs-bot decisions can diverge.

Bots currently support Attrition-style PvP rulesets. Public, ask-first,
matchmaking, team, cooperative, and in-progress lobbies do not expose the add
button. The ruleset and gamemode selectors show the current bot-support status.
All human players and bots must use the same mod set required by the lobby server.
If only bots remain, the bot with the most lives wins; tied bots are ranked by
their score in the last PvP Blind, then by the lowest player ID.
Unsupported Jokers are automatically sold when the bot next enters a shop.

## Copy-Joker search

Blueprint and Brainstorm trigger exhaustive Joker-order scoring through seven
slots. Resolved copy effects are cached per decision and reused across candidate
hands, preserving exact choices while avoiding repeated copy-chain resolution.
The order search itself remains factorial at six and seven slots.

## Decision logging

Each match creates `logs/multibots-<timestamp>.log` with the header
`MULTIBOTS_LOG v2 encoding=percent`. It is the compact strategy/training log;
Lovely output is not needed for normal decision review. Values escape whitespace,
`=`, and `%` as percent bytes, so every record stays on one parseable line.

Meaningful simulator actions use monotonic `decision_id` values. Hand decisions
include the pre-action hand, ordered Jokers, consumables, plan, score pressure,
resources, top three candidates plus the chosen candidate, utilities, regret, and
a `snapshot_id` reference. Shop decisions include every offered
key, supported keys, evaluated known offers, buy/skip choice, replacement,
reserve reason, best alternative, and regret.

Typical records (wrapped here only for readability):

```text
MULTIBOTS_LOG v2 encoding=percent difficulty=expert high_regret_threshold=25
04:12:31 DECISION decision_id=483 action=play ante=5 round=Big
  current_score=18200 required_score=22000 hands_remaining=2 discards_remaining=1
  candidates=play~1,2~91.700~Pair~6400;discard~3,4,5~60.000~~
  chosen_utility=60 best_utility=91.7 regret=31.7 snapshot_id=483
04:13:02 SHOP_DECISION decision_id=490 shop_id=5:9
  offered=j_blueprint,j_unknown supported=j_blueprint evaluated=j_blueprint~joker~10~42.000
  chosen=buy_joker:j_blueprint best_alternative=skip reserve_reason=preserves_reserve regret=0
```

Full replay state is stored separately in
`logs/multibots-<timestamp>.snapshots.log`, keyed by the same decision ID. This
keeps routine decision lines small while retaining exact deck, draw, Joker, and
resource state when a case is selected for review.

The logger writes `logs/multibots-<timestamp>.report.txt` only when the player
beats the bot. The report includes PvP scores, both final builds, and captured
player plays, discards, and shop actions with pre-action state. It names weight
areas to review, but does not infer a weight-change direction or update weights:
one run does not prove which preference caused the win. Bot wins retain the
compact decision log without a strategy report. Technical information is
separate and lazy: a `multibots-debug-<timestamp>.log` is created only when
MultiBots records a network/runtime/invalid-action problem. Lovely remains
useful when game state and bot state disagree, a hook fails, or a crash
prevents the normal report.

## Post-match analyzer

Run the standalone reducer from the mod directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\analyze-log.ps1 `
  .\logs\multibots-2026.10.13-04.12.20.log
```

It prints and writes a compact `.report.txt`. It reads the matching
`.snapshots.log` store and writes only selected cases to
`.flagged-snapshots.log`. Thresholds default to `config.lua` values captured in
the log header and can be overridden:

```powershell
.\tools\analyze-log.ps1 .\logs\multibots-....log `
  -RegretThreshold 20 -VarianceRatio 5 -ReorderThreshold 4
```

The report contains blind deficit percentages, near-miss tiers, unused
hands/discards/consumables, suspicious resource conservation, PvP margins,
unique unsupported objects and total encounters, Joker lifecycle events,
repeated Blueprint/Brainstorm reorders, technical failures, high-regret choices,
and score variance following a plan change. Regret is
`max(0, best_candidate_utility - chosen_candidate_utility)`; outcome anomalies
remain useful when Expert assigns its chosen action the highest utility and
therefore records zero internal regret.

Snapshots already preserve enough state for compact regression fixtures and a
future deterministic replay entry point: seed, decision location, hand, draw
pile and deck, Joker order/state/editions, hand levels, consumables, economy,
score pressure, and plan.
Full interactive replay, self-play orchestration, and ML ingestion are not yet
implemented; the stable IDs and structured records are intended as their input.

## Strategy-weight training

The live evaluator's trainable preference multipliers are centralized in
`bot/weights.lua`. Every default is `1.0`, which preserves the previous formulas.
They cover immediate/future score, discard potential, card preservation,
survival pressure, plan alignment, Joker base value and synergy, economy and
interest preservation, packs, deck manipulation, consumables, and risk
tolerance. Rules, legality checks, card effects, and card-specific mechanics are
not trainable.

Measure the unchanged Expert baseline:

```powershell
.\tools\train.ps1 -Mode baseline
```

Run deterministic evolution using the training seeds. The strongest configured
slice of each generation is evaluated on a separate validation set:

```powershell
.\tools\train.ps1 -Mode train -PopulationSize 8 -Generations 10
```

To optimize against recorded player PvP scores, pass one or more match logs.
Start from the active trained profile so evolution improves that profile rather
than restarting from default weights:

```powershell
.\tools\train.ps1 -Mode train `
  -StartWeightsPath .\training\results\current\best-weights.lua `
  -PlayerLogs .\logs\multibots-player-run-1.log,.\logs\multibots-player-run-2.log `
  -PopulationSize 8 -Generations 10
```

Use `-PlayerLogs latest` to select the most recently updated match log containing
PvP player scores. The full-training shortcut uses this option and starts from
the current trained profile.

Each seed is paired with one recorded opponent trace, so every candidate sees
the same human score schedule for that seed. PvP win rate now has equal fitness
weight to full-run survival. Training still selects by held-out validation and
test results; it never promotes candidate weights automatically. Training writes
`weight-recommendations.txt` in each output directory with exact candidate weight
changes and paired validation/test evidence. Treat those as measured candidates,
not guaranteed improvements; player action counts alone cannot determine weight
magnitudes.

The console reports each match start and finish, its phase and seed, and its
elapsed simulation time. During evolution, it also shows a per-generation
progress bar and percentage across training and validation matches. The Python
parallel runner echoes worker output and updates its combined progress bar for
seed-selection matches as well as evolution matches. A match that takes
unusually long remains visible as running; generation summaries report
completed selection.

`training_seeds`, `validation_seeds`, and `test_seeds` are ordinary configurable
arrays; experiments such as 32/16/32 require no code changes.

Configuration—including seeds, mutation settings, opponent, and fitness term
weights—is in `training/config.lua`. A run writes to a timestamped directory
under `training/results/`: `generation-NNN.json`, `checkpoint.lua`,
`result.json`, `best-training-weights.lua`, `best-validation-weights.lua`, and
`best-weights.lua`. `champion-weights.lua` is the same frozen selected candidate
for multi-experiment tournament input. The live
mod never loads it automatically. Resume a longer run without changing its RNG
stream:

```powershell
.\tools\train.ps1 -Mode train -PopulationSize 8 -Generations 50 `
  -OutputDirectory training\results\my-run `
  -ResumeCheckpoint training\results\my-run\checkpoint.lua
```

Compare saved weights against the current Expert baseline on all three seed sets:

```powershell
.\tools\train.ps1 -Mode compare `
  -WeightsPath training\results\my-run\best-weights.lua
```

Run independent experiments in parallel without sharing evolutionary RNG state.
Python 3 is required for this mode. By default, it uses up to one worker per
logical CPU; set `-MaxWorkers` to cap CPU and memory use. The combined progress
bar stays pinned to the bottom of interactive terminals while match output
scrolls above it. It reaches 100% only when all workers finish.

```powershell
.\tools\train.ps1 -Mode train -ExperimentCount 4 `
  -PopulationSize 8 -Generations 20 `
  -MaxWorkers 4 `
  -OutputDirectory training\results\experiment-group
```

Each `experiment_NNN` directory saves `champion-weights.lua`. Champions are
never promoted automatically. Evaluate them on one shared 128-seed unseen set:

```powershell
.\tools\train.ps1 -Mode tournament `
  -ChampionPaths @(
    'training\results\experiment-group\experiment_001\champion-weights.lua',
    'training\results\experiment-group\experiment_002\champion-weights.lua'
  )
```

  Each worker runs a complete Lua experiment. Matches within one experiment
  remain sequential, so use `-ExperimentCount` to parallelize independent searches.

The fitness output includes per-Ante clear rates, average Ante, survival, score
margin, failed-blind deficit and unused resources, money, PvP results, invalid
states, crashes, and configured regression failures. `fitness_contributions`
shows the exact contribution of every term. Crashes and invalid states have
large default penalties.

For every candidate and seed, the trainer compares candidate fitness with the
unchanged baseline on the same seed and opponent conditions. Rotating-batch
ranking defaults to `mean_delta - 0.10 * delta_stddev`; raw candidate fitness is
diagnostic only. `paired_objective` can instead use `weighted_mean_win_rate`.
Training, validation, test, comparison, and tournament JSON include per-seed
fitness, delta, winner, survival, clear rate, Ante, and score margin. Summaries
include wins, losses, ties, mean, median, standard deviation, standard error,
95% confidence interval, worst delta, and best delta.

The top paired-training candidates receive fixed-set paired validation. Final
selection uses paired validation objective and the configurable mean-delta,
win-rate, raw validation improvement, survival, and clear-rate floors.

The test seeds are not evaluated during evolution, validation ranking, plateau
detection, or final selection. Only after selection is frozen are baseline and
the selected candidate evaluated on the test set. `test_improved` is therefore
an untouched estimate rather than another selection signal. Seed overlap across
the three sets is rejected.

Validation plateaus are reported after the configured number of generations
without meaningful improvement. Training stops early after `patience` plateau
generations once `minimum_generations` is reached. Exact training elites are
retained, while every non-elite child is guaranteed at least one mutation.
`auto_promoted` always remains false. `promotion_eligible` becomes true only
after the frozen candidate passes both validation and untouched-test thresholds.

Each new `tools/train.ps1` invocation creates a fresh random experiment seed and
deterministically expands it into configurable train/validation/test sets.
Defaults are 16/8/16; change the three counts under `seed_generation` for larger
runs. With `rotate_training_each_generation=true`, every generation derives a
new training batch from the experiment seed and generation number. All candidates
in that generation—including a fresh baseline evaluation—see the same batch, so
ranking remains fair. Cross-generation strength uses the paired objective, not
raw scores from different batches. Validation and test candidates are generated
from larger pools, classified as `easy`, `medium`, `hard`, or `very_hard` using
baseline survival, clear rate, Ante, and failed-blind performance, then selected
round-robin across populated bands. Validation stays fixed and test stays
untouched until selection finishes.

The experiment seed and reference sets are saved in `seed-manifest.json`; each
generation JSON also records its actual training batch. Checkpoint resume restores
the experiment exactly. Use `-ExperimentSeed NAME` to reproduce it deliberately;
otherwise a later run explores a new distribution instead of repeatedly
optimizing the original fixtures.

## Activating trained weights

Live use is deliberately opt-in. Root `config.lua` contains a disabled
`strategy_weights` profile. To promote a future candidate, copy the table entries
from its `best-weights.lua` into `strategy_weights.values`, give it a descriptive
name, set `enabled = true`, and restart Balatro. Values are validated before a
match; empty, unknown, nonnumeric, or out-of-range profiles fall back to defaults
with a warning. The active profile name is written into the strategy log header.
Turning `enabled` back to `false` immediately restores the original defaults on
the next match. Trainer output is never copied or activated automatically.

`training/opponents.lua` keeps PvP pressure independent of the trainer and
supports deterministic scripted pressure, no opponent, and recorded score
traces. `training/snapshot_branch.lua` loads snapshot sidecars and compares
candidate actions through an injected offline simulation adapter, including
multiple deterministic continuations and simulated regret. The state-restoring
adapter itself is intentionally still pending: current compact snapshots need a
full deserializer for cards, draw order, Joker state, and round internals before
they can drive exact multi-turn replay. This offline module is not imported by
live gameplay, so hidden future information cannot leak into Expert decisions.
