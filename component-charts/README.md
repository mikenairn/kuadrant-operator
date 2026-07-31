# Component Charts

This directory contains Helm charts synced from upstream component repos. **Do not edit files in this directory manually** — they are managed by the sync tool and will be overwritten on the next sync.

## How it works

Charts are downloaded as-is from upstream repos based on the configuration in `sync.yaml`. Each component directory contains the complete upstream chart (Chart.yaml, values.yaml, templates/, crds/).

## Syncing

```bash
# Sync all components
make sync-component-charts

# Sync a single component
make sync-component-chart COMPONENT=dns-operator
```

## Configuration

Edit `sync.yaml` to change which upstream refs are tracked. See the field descriptions in that file for details.
