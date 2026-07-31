package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

func main() {
	configPath := flag.String("config", "component-charts/sync.yaml", "Path to sync config file")
	component := flag.String("component", "", "Sync a specific component (default: all)")
	refOverride := flag.String("ref", "", "Override ref for the sync (requires --component)")
	query := flag.String("query", "", "Output tracking info for a component as JSON (no sync)")
	flag.Parse()

	cfg, err := LoadConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}

	if *query != "" {
		queryComponent(cfg, *query)
		return
	}

	if *refOverride != "" && *component == "" {
		fmt.Fprintf(os.Stderr, "Error: --ref requires --component\n")
		os.Exit(1)
	}

	syncComponents(cfg, *configPath, *component, *refOverride)
}

func queryComponent(cfg *SyncConfig, name string) {
	c, ok := cfg.Components[name]
	if !ok {
		fmt.Fprintf(os.Stderr, "Error: component %q not found in config\n", name)
		os.Exit(1)
	}

	out := struct {
		TrackedBranch string `json:"tracked-branch"`
		AutoMerge     bool   `json:"auto-merge"`
	}{
		TrackedBranch: c.TrackedBranch,
		AutoMerge:     c.AutoMerge,
	}

	enc := json.NewEncoder(os.Stdout)
	if err := enc.Encode(out); err != nil {
		fmt.Fprintf(os.Stderr, "Error encoding JSON: %v\n", err)
		os.Exit(1)
	}
}

func syncComponents(cfg *SyncConfig, configPath, component, refOverride string) {
	outputBase := filepath.Dir(configPath)

	components := cfg.Components
	if component != "" {
		c, ok := cfg.Components[component]
		if !ok {
			fmt.Fprintf(os.Stderr, "Error: component %q not found in config\n", component)
			os.Exit(1)
		}
		if refOverride != "" {
			c.Ref = refOverride
		}
		components = map[string]Component{component: c}
	}

	failed := false
	for name, c := range components {
		chartDir := filepath.Join(outputBase, name)
		fmt.Printf("Syncing %s from %s@%s\n", name, c.Repo, c.Ref)

		oldHash, _ := hashDir(chartDir)

		tmpDir, err := os.MkdirTemp(outputBase, ".sync-component-*")
		if err != nil {
			fmt.Fprintf(os.Stderr, "Error creating temp dir: %v\n", err)
			failed = true
			continue
		}

		if err := DownloadChart(c.Repo, c.Ref, c.ChartPath, tmpDir); err != nil {
			os.RemoveAll(tmpDir)
			fmt.Fprintf(os.Stderr, "Error syncing %s: %v\n", name, err)
			failed = true
			continue
		}

		newHash, _ := hashDir(tmpDir)

		if oldHash == newHash {
			os.RemoveAll(tmpDir)
			fmt.Printf("  No changes.\n")
			continue
		}

		if err := os.RemoveAll(chartDir); err != nil {
			os.RemoveAll(tmpDir)
			fmt.Fprintf(os.Stderr, "Error removing %s: %v\n", chartDir, err)
			failed = true
			continue
		}
		if err := os.Rename(tmpDir, chartDir); err != nil {
			fmt.Fprintf(os.Stderr, "Error moving chart to %s: %v\n", chartDir, err)
			failed = true
			continue
		}

		fmt.Printf("  Updated.\n")
	}

	if failed {
		os.Exit(1)
	}
}

func hashDir(dir string) (string, error) {
	h := sha256.New()
	var files []string

	err := filepath.Walk(dir, func(path string, info os.FileInfo, err error) error {
		if err != nil || info.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(dir, path)
		files = append(files, rel)
		return nil
	})
	if err != nil {
		return "", err
	}

	sort.Strings(files)
	for _, f := range files {
		fmt.Fprintf(h, "%s\n", f)
		data, err := os.ReadFile(filepath.Join(dir, f))
		if err != nil {
			return "", err
		}
		h.Write(data)
	}

	return hex.EncodeToString(h.Sum(nil)), nil
}
