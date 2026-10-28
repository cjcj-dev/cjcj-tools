# Real project consumers

`compilation-database.mjs <installed-cjpm> <fresh-work> <analysis-prefix>` runs the selected CJC through normal workspace/path/binary builds and the explicit -i cache branch. The prefix supplies the existing core and no-macro leaf; the binary leaf is copied into CJPM's normal package-directory layout without recompiling it. The supplied host environment must execute CJPM/CJC and provide the target's native tools; it must not replace the analysis core with host modules.

`project-refresh.mjs <installed-cjpm> <successful-project> <fresh-work>` checks target-specific cfg, first/cache equality, real type-error compiler rejection and stale database removal/recovery. `project-configuration.mjs <installed-cjpm> <project> <fresh-evidence>` normally builds two selected cfg values for the LSP configuration-refresh consumer. Neither script forges a database or CJO.

The normal default (non-incremental) branch may compile on every invocation; cache assertions require -i. Existing jobserver/MAKEFLAGS/watcher behavior is unchanged. Product build and tool tests are distinct from full SDK and other-platform qualification.
