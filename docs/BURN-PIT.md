# Burn Pit

Open **Findings → Burn Pit** in the Mac app. Burn Pit scans in the background when first opened. Reopening the window retains the last snapshot and refreshes it if it is more than a minute old. **Refresh** requests a new snapshot.

Slab area shows estimated disk usage. Select a slab to inspect its path, status, source and observation time. Use the **Disk folders** layer for directory measurements. **Evidence Ledger** includes overlapping paths, smaller items and findings with unknown size. The **Zombie signals** layer opens directly in the ledger and reports resident RAM when it is available.

The read-only browser version uses the same BurnCore snapshot.

```sh
swift run burnzombies map --demo --open
swift run burnzombies map --open
```

Omit `--open` to print the private local HTML path. Use `--json` to write the snapshot to stdout. Live snapshots may contain local paths and diagnostic text. Demo snapshots use sample data.

Storage estimates are bounded and can overlap or share APFS blocks. Estimated disk usage does not predict how many bytes APFS would free. Saved inventory shows its source and observation time. Snapshot coverage explains which locations and findings the scan includes.
