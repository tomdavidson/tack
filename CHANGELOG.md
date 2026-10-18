# Changelog

## [1.1.0](https://github.com/tomdavidson/tack/compare/v1.0.0...v1.1.0) (2026-10-18)


### Features

* add cfg pkg file ignore option ([dfe0528](https://github.com/tomdavidson/tack/commit/dfe0528539a8684fa499a467a69d847127af0cfa))
* add configs/php and configs/drupal packages ([#16](https://github.com/tomdavidson/tack/issues/16)) ([c7e5638](https://github.com/tomdavidson/tack/commit/c7e563847c0fe634f541cd210d8d8f8c0751de01))
* bootstrap script and committed materialization model ([#10](https://github.com/tomdavidson/tack/issues/10)) ([6d185a2](https://github.com/tomdavidson/tack/commit/6d185a2f7599aed524a63263db4c3bd5178ad072))
* bootstrap yq/tera via proto, dogfood tack, fail loudly on broken bwrap ([#27](https://github.com/tomdavidson/tack/issues/27)) ([3bbe434](https://github.com/tomdavidson/tack/commit/3bbe434647dc966d81e46cb9bfb7541e6c0a8f8f))
* bubblewrap sandboxing for devenv tools ([#15](https://github.com/tomdavidson/tack/issues/15)) ([0682287](https://github.com/tomdavidson/tack/commit/0682287f3251c2b113b0d6d056628f960ce43328))
* **ci:** add Renovate config ([#8](https://github.com/tomdavidson/tack/issues/8)) ([3314664](https://github.com/tomdavidson/tack/commit/3314664a17633ff14fd6e2042b7f38d30fa5026f))
* **ci:** enable release-please, enforce conventional PR gate, and dogfood RAA ([#41](https://github.com/tomdavidson/tack/issues/41)) ([87a933a](https://github.com/tomdavidson/tack/commit/87a933a8d2e2e9ee9b9aa71746878d54f292c6f9))
* **configs:** add devcontainer and devenv packages, ADR-0006, update defaults and gitignore ([#4](https://github.com/tomdavidson/tack/issues/4)) ([9fdd1d8](https://github.com/tomdavidson/tack/commit/9fdd1d869a50fa157430ba8d8bfe6e990f7680fb))
* **devenv:** bubblewrap sandboxing for dependency-executing tools ([0682287](https://github.com/tomdavidson/tack/commit/0682287f3251c2b113b0d6d056628f960ce43328))
* **devenv:** replace concat with drupal stack-import pattern ([#19](https://github.com/tomdavidson/tack/issues/19)) ([ffb8dab](https://github.com/tomdavidson/tack/commit/ffb8dabac299b6f353233f6a150145f1764756fa))
* **devenv:** replace concat with stack-import pattern ([#17](https://github.com/tomdavidson/tack/issues/17)) ([94a3e4e](https://github.com/tomdavidson/tack/commit/94a3e4e67a47a985f495ea75eb7a3f825e0b4857))
* dprint.json as a remote config ([98ec2f9](https://github.com/tomdavidson/tack/commit/98ec2f97ad0adeb94ef3c3784b0436d00e832dd0))
* drupal config — variants, moon task split, servicfeat(drupal): localgov-multisite variant, moon task split, Fly scaffoldinge scaffolding ([#22](https://github.com/tomdavidson/tack/issues/22)) ([7e7b1f8](https://github.com/tomdavidson/tack/commit/7e7b1f818a46cf12ad2c4aeea4fad289bc2b7f07))
* **drupal/stacks:** full localgov-multisite stack ([#20](https://github.com/tomdavidson/tack/issues/20)) ([ee999c3](https://github.com/tomdavidson/tack/commit/ee999c3dd72150c877ad5ed427045a5c70366e24))
* **drupal/variants:** add `logs` script to localgov-multisite devenv ([#24](https://github.com/tomdavidson/tack/issues/24)) ([2e86aec](https://github.com/tomdavidson/tack/commit/2e86aec339047b69907b63e0c117a53eb33982d7))
* **drupal:** add dlg-ms variant, split base drupal.nix, per-app composer ([#25](https://github.com/tomdavidson/tack/issues/25)) ([c2456f0](https://github.com/tomdavidson/tack/commit/c2456f0818aa628a342123f521e36cc241cabd8b))
* extend devenv template for languages and services ([#11](https://github.com/tomdavidson/tack/issues/11)) ([7406ccb](https://github.com/tomdavidson/tack/commit/7406ccb14d09b9b5b0e46209f02164a82b6afbce))
* **image:** add tack-dev base image, global prototools, and ADR-0005 ([56702ec](https://github.com/tomdavidson/tack/commit/56702ec5073a5836476cd2019b49acd33dd35378))
* **image:** tack-dev base image, global prototools, ADR-0005 ([abe42e8](https://github.com/tomdavidson/tack/commit/abe42e8f220af147c01a2e7b2384693fbe6d1e1b))
* path prefix support for config pkgs (tack.yml schema) ([45b187e](https://github.com/tomdavidson/tack/commit/45b187e44fedfc2dff89c2749a60448ff1865f82))
* python pack, writable .tack sandbox (ADR-0008), linked root moon.yml (ADR-0009) ([#39](https://github.com/tomdavidson/tack/issues/39)) ([da68ace](https://github.com/tomdavidson/tack/commit/da68ace7969c0771811b49735f855434e8f009a8))
* tack overwrite & ignore. rust cli pattern ([9525060](https://github.com/tomdavidson/tack/commit/95250607f1e2103a5bd5fb200829d2badcb7aa33))
* unify lint baselines, ADR-0009/0010 delivery & Moon tasks, Renovate split, and docs ([#40](https://github.com/tomdavidson/tack/issues/40)) ([d1b6402](https://github.com/tomdavidson/tack/commit/d1b6402a43889ede8731be836192a2a13d9b916c))


### Bug Fixes

* **ci:** add missing setup action alias (was checkout-and-setup) ([#5](https://github.com/tomdavidson/tack/issues/5)) ([2df8001](https://github.com/tomdavidson/tack/commit/2df80019c2b6c7e8458076c225db8b970fa071fd))
* **ci:** pin proto to 0.62.3 in setup actions (yq plugin requires &gt;=0.57.0) ([#7](https://github.com/tomdavidson/tack/issues/7)) ([cbf6009](https://github.com/tomdavidson/tack/commit/cbf6009105659a4b0d67bb680a848c5d7cf1e18c))
* **configs:** tack.yml files keys must be source (tera) filenames not target names ([#6](https://github.com/tomdavidson/tack/issues/6)) ([a90d0a2](https://github.com/tomdavidson/tack/commit/a90d0a2aa0489c8451e3b8f20ffbafe5f143388e))
* ingore semantics ([917c0a7](https://github.com/tomdavidson/tack/commit/917c0a7fb97913679a0d94be5ba99e19c63a7d1b))
* ingore semantics ([0bc15d3](https://github.com/tomdavidson/tack/commit/0bc15d3fde83d20952fe056d1d0c53f1577cf7e6))
* relative .prototools symlink (absolute path broke action download) ([5ffd489](https://github.com/tomdavidson/tack/commit/5ffd489d1955c48947d6b7630f7395bac3c91f8e))
* replace existing links ([996598c](https://github.com/tomdavidson/tack/commit/996598cc419d157c75cdce34c54aa5f145e0c470))
* script pkg needs prefix ([85e1318](https://github.com/tomdavidson/tack/commit/85e13182e26a6003b4581d8eb56c2fc058808a07))
* syntax ([5a15710](https://github.com/tomdavidson/tack/commit/5a15710a96fe2a3e2a008f1ba259166eaee6300c))
* **tack.sh:** never write through symlinked destinations; add --overwrite ([#28](https://github.com/tomdavidson/tack/issues/28)) ([1c34925](https://github.com/tomdavidson/tack/commit/1c34925f6a822c8d3ec03940afebd4671b1acaf3))


### Documentation

* add code pattern ([af4254f](https://github.com/tomdavidson/tack/commit/af4254facf949047ea627720103cdf9a5fa154c8))
* add code pattern ([313190e](https://github.com/tomdavidson/tack/commit/313190e89f4edcde399e3b05003a16ca5abea009))
* explain moon sandbox scope and per-tool gap (see issue [#13](https://github.com/tomdavidson/tack/issues/13)) ([#14](https://github.com/tomdavidson/tack/issues/14)) ([522d684](https://github.com/tomdavidson/tack/commit/522d6844cc154905ce71503fb9e94a58d6bc529c))
