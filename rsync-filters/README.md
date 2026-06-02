# rsync-filters

Each backup job uses `default.rsync-filter` as its base filter.

If a file named `<job_name>.rsync-filter` exists in this directory, it is merged on top of the default filter and applied to that job only.
