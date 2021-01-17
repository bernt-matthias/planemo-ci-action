Planemo discover action
=======================

Installs planemo and discovers changed workflows and tools to test.

The action runs in one of six modes which are controled with the following
boolean inputs:

- `lint-tools`: Lint tools with `planemo shed_lint` and check presence of repository metadata files (`.shed.yml`).
- `test-tools`: Test tools with `planemo test`.
- `combine-outputs`: Combine the outputs from individual tool tests (`planemo merge_test_reports`) and create html/markdown reports (`planemo test_reports`).
- `check-outputs`: Check if any of the tests failed.
- `deploy-tool`: Deploy tools to a toolshed using `planemo shed_update`.

If none of these inputs is set then a setup mode runs.

Setup mode
----------
