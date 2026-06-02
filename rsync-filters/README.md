# rsync-filters

If `default.rsync-filter` exists in this directory, it is applied to all backup jobs as the base filter.

If a file named `<job_name>.rsync-filter` exists in this directory, it is merged on top of the default filter and applied to that job only.
