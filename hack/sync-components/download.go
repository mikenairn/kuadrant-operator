package main

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

func DownloadChart(repo, ref, chartPath, outputDir string) error {
	url := fmt.Sprintf("https://api.github.com/repos/%s/tarball/%s", repo, ref)

	resp, err := http.Get(url)
	if err != nil {
		return fmt.Errorf("HTTP GET %s: %w", url, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("HTTP %d from %s", resp.StatusCode, url)
	}

	return ExtractChart(resp.Body, chartPath, outputDir)
}

func ExtractChart(r io.Reader, chartPath, outputDir string) error {
	gz, err := gzip.NewReader(r)
	if err != nil {
		return fmt.Errorf("gzip reader: %w", err)
	}
	defer gz.Close()

	prefix := chartPath + "/"
	tr := tar.NewReader(gz)
	found := false

	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("reading tar: %w", err)
		}

		// GitHub tarballs have a top-level dir like "Org-Repo-SHA/"
		parts := strings.SplitN(hdr.Name, "/", 2)
		if len(parts) < 2 {
			continue
		}
		relPath := parts[1]

		if !strings.HasPrefix(relPath, prefix) {
			continue
		}
		found = true

		targetPath := filepath.Join(outputDir, strings.TrimPrefix(relPath, prefix))

		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(targetPath, 0o755); err != nil {
				return fmt.Errorf("creating dir %s: %w", targetPath, err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
				return fmt.Errorf("creating parent dir for %s: %w", targetPath, err)
			}
			f, err := os.Create(targetPath)
			if err != nil {
				return fmt.Errorf("creating file %s: %w", targetPath, err)
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return fmt.Errorf("writing file %s: %w", targetPath, err)
			}
			f.Close()
		}
	}

	if !found {
		return fmt.Errorf("chart path %q not found in tarball", chartPath)
	}
	return nil
}
