# Contributing

Keep the core independent of Half Sword's property names. Game-specific behavior
belongs in a profile/plugin. New profiles need their own build and runtime tests.

Add a regression test for lifecycle, cleanup, queue or mesh-validation changes.
Do not replace a failed in-game test with a passing mock test in the compatibility
report. Use `docs/validation.md` to state what was and was not observed.

Contributions are accepted under MIT. Preserve applicable dependency licenses and
do not submit game assets, save files, credentials or proprietary SDK dumps.
