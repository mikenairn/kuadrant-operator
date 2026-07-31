package main

import (
	"fmt"
	"os"

	"gopkg.in/yaml.v3"
)

type Component struct {
	Repo          string `yaml:"repo"`
	ChartPath     string `yaml:"chart-path"`
	TrackedBranch string `yaml:"tracked-branch"`
	Ref           string `yaml:"ref"`
	AutoMerge     bool   `yaml:"auto-merge"`
}

type SyncConfig struct {
	Components map[string]Component `yaml:"components"`
}

func LoadConfig(path string) (*SyncConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("reading config: %w", err)
	}

	var cfg SyncConfig
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parsing config: %w", err)
	}

	if len(cfg.Components) == 0 {
		return nil, fmt.Errorf("no components defined in %s", path)
	}

	for name, c := range cfg.Components {
		if c.Repo == "" {
			return nil, fmt.Errorf("component %q: repo is required", name)
		}
		if c.ChartPath == "" {
			return nil, fmt.Errorf("component %q: chart-path is required", name)
		}
		if c.Ref == "" {
			return nil, fmt.Errorf("component %q: ref is required", name)
		}
	}

	return &cfg, nil
}
