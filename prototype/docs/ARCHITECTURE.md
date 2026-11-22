# Project structure

The project starts the playable match in `main.tscn` and `scripts/game/PrototypeMatch.gd`. The art sandbox remains available at `scenes/art_sandbox/ArtSandbox.tscn` for appearance tuning.

The cosmic skin uses illustrated art under `assets/orbs/` and `assets/arena/`. The match scene draws the angled celestial board and the fire, iron, and vampire orbs. The six-sided collision field follows the sloped top and bottom rails. Towers are mounted at the four sloped-wall corners and the two center peaks; only a narrow inward fan at each tower can be hit. Tangential tower contact adds ball spin, so glancing and centered shots behave differently. Iron survives tower hits; fire is consumed; vampire deals damage to an opposing tower and restores that amount to the most damaged surviving friendly tower, capped at 100 HP.

## New visual foundation

- `scripts/data/` contains editable Resource definitions. `BallVisualProfile` is art-only; `BallPhysicsProfile` contains motion values; `BallRuleProfile` contains impact and respawn rules; `BallArchetype` composes those profiles. `ArenaDefinition` describes physical map layout, while `ArenaTheme` describes its appearance.
- `scripts/visuals/` contains reusable drawing nodes. `BallVisual` renders a sphere, animated surface pattern, blink, spin decay, glow, and selection/hit rings. `ArenaVisual` renders the floor, grid, border, corner rails, and border pulse.
- `scripts/sandbox/ArtSandbox.gd` previews all ball profiles and exposes live appearance controls. It saves tuned resources under `resources/custom_art_profiles/`.
- `resources/ball_visuals/`, `resources/arena_themes/`, and `resources/arenas/` hold starter presets.

## Next integration boundary

After the visual style is approved, move match state and collision updates into `scripts/simulation/MatchSimulation.gd`, turn/death/respawn transitions into `scripts/rules/TurnManager.gd`, and connect the existing match scene to `BallVisual` and `ArenaVisual`. Later, `scripts/networking/` should send player actions to the authoritative match simulation and relay its state/events. The current prototype remains playable while that migration is done in small steps.
