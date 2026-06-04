# rsync-filters

You can control what gets included or excluded from backups with rsync’s versatile filtering.

If `default.rsync-filter` exists in this directory, it is applied to all backup jobs:

```
rsync … --filter="merge default.rsync-filter" …
```

If `<job_name>.rsync-filter` exists in this directory, it is applied to that job only:

```
rsync … --filter="merge <job_name>.rsync-filter" …
```

If both exist, the per-job filter is applied on top of the default one:

```
rsync … --filter="merge default.rsync-filter" --filter="merge <job_name>.rsync-filter" …
```

See [FILTER RULES](https://download.samba.org/pub/rsync/rsync.1#FILTER_RULES) in the [rsync(1) manpage](https://download.samba.org/pub/rsync/rsync.1) for the full rule syntax.
