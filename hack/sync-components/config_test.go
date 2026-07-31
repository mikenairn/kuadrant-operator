package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadConfig(t *testing.T) {
	tests := []struct {
		name      string
		yaml      string
		wantCount int
		wantErr   bool
		check     func(t *testing.T, cfg *SyncConfig)
	}{
		{
			name: "single component",
			yaml: `components:
  dns-operator:
    repo: Kuadrant/dns-operator
    chart-path: charts/dns-operator
    tracked-branch: main
    ref: main
`,
			wantCount: 1,
			check: func(t *testing.T, cfg *SyncConfig) {
				c, ok := cfg.Components["dns-operator"]
				if !ok {
					t.Fatal("dns-operator not found")
				}
				if c.Repo != "Kuadrant/dns-operator" {
					t.Errorf("repo = %q, want %q", c.Repo, "Kuadrant/dns-operator")
				}
				if c.ChartPath != "charts/dns-operator" {
					t.Errorf("chart-path = %q, want %q", c.ChartPath, "charts/dns-operator")
				}
				if c.TrackedBranch != "main" {
					t.Errorf("tracked-branch = %q, want %q", c.TrackedBranch, "main")
				}
				if c.Ref != "main" {
					t.Errorf("ref = %q, want %q", c.Ref, "main")
				}
			},
		},
		{
			name: "multiple components",
			yaml: `components:
  dns-operator:
    repo: Kuadrant/dns-operator
    chart-path: charts/dns-operator
    tracked-branch: main
    ref: main
  mcp-gateway:
    repo: Kuadrant/mcp-gateway
    chart-path: charts/mcp-gateway
    tracked-branch: main
    ref: v0.1.0
`,
			wantCount: 2,
			check: func(t *testing.T, cfg *SyncConfig) {
				mcpgw := cfg.Components["mcp-gateway"]
				if mcpgw.Ref != "v0.1.0" {
					t.Errorf("mcp-gateway ref = %q, want %q", mcpgw.Ref, "v0.1.0")
				}
			},
		},
		{
			name:    "empty file",
			yaml:    "",
			wantErr: true,
		},
		{
			name: "missing required field repo",
			yaml: `components:
  dns-operator:
    chart-path: charts/dns-operator
    tracked-branch: main
    ref: main
`,
			wantErr: true,
		},
		{
			name: "missing required field chart-path",
			yaml: `components:
  dns-operator:
    repo: Kuadrant/dns-operator
    tracked-branch: main
    ref: main
`,
			wantErr: true,
		},
		{
			name: "missing required field ref",
			yaml: `components:
  dns-operator:
    repo: Kuadrant/dns-operator
    chart-path: charts/dns-operator
    tracked-branch: main
`,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "sync.yaml")
			if err := os.WriteFile(path, []byte(tt.yaml), 0o644); err != nil {
				t.Fatal(err)
			}

			cfg, err := LoadConfig(path)
			if tt.wantErr {
				if err == nil {
					t.Fatal("expected error, got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(cfg.Components) != tt.wantCount {
				t.Errorf("component count = %d, want %d", len(cfg.Components), tt.wantCount)
			}
			if tt.check != nil {
				tt.check(t, cfg)
			}
		})
	}
}
