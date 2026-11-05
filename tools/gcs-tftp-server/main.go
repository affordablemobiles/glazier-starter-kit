package main

import (
	"bytes"
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"os/signal"
	"path"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/pin/tftp/v3"
)

type cacheEntry struct {
	data      []byte
	expiresAt time.Time
}

var (
	bucket     = flag.String("bucket", getEnv("GCS_BUCKET", ""), "Public Google Cloud Storage bucket name (required, or set GCS_BUCKET)")
	prefix     = flag.String("prefix", getEnv("GCS_PREFIX", ""), "Optional object path prefix inside the bucket")
	listenAddr = flag.String("listen", getEnv("TFTP_LISTEN", ":69"), "UDP address and port to listen on")
	timeout    = flag.Duration("timeout", getEnvDuration("TFTP_TIMEOUT", 5*time.Second), "TFTP packet timeout")
	retries    = flag.Int("retries", 5, "TFTP packet retry count")
	cacheTTL   = flag.Duration("cache-ttl", getEnvDuration("CACHE_TTL", 5*time.Minute), "In-memory cache TTL for fetched objects (0s to disable)")
	singlePort = flag.Bool("single-port", getEnvBool("TFTP_SINGLE_PORT", true), "Serve all TFTP traffic on a single UDP port (Docker/firewall friendly)")

	httpClient = &http.Client{Timeout: 30 * time.Second}
	cacheMu    sync.RWMutex
	memCache   = make(map[string]cacheEntry)
)

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getEnvDuration(key string, fallback time.Duration) time.Duration {
	if v := os.Getenv(key); v != "" {
		if d, err := time.ParseDuration(v); err == nil {
			return d
		}
	}
	return fallback
}

func getEnvBool(key string, fallback bool) bool {
	if v := os.Getenv(key); v != "" {
		switch strings.ToLower(strings.TrimSpace(v)) {
		case "1", "true", "yes", "on":
			return true
		case "0", "false", "no", "off":
			return false
		}
	}
	return fallback
}

// cleanObjectPath normalizes UEFI PXE paths (strips null bytes, converts '\' to '/', prevents '../' traversal)
func cleanObjectPath(raw string) (string, error) {
	p := strings.TrimRight(raw, "\x00")
	p = strings.ReplaceAll(p, "\\", "/")
	p = path.Clean("/" + p)
	p = strings.TrimPrefix(p, "/")
	if p == "" || p == "." || strings.HasPrefix(p, "..") {
		return "", fmt.Errorf("invalid filename %q", raw)
	}
	if *prefix != "" {
		cleanPfx := strings.Trim(strings.ReplaceAll(*prefix, "\\", "/"), "/")
		if cleanPfx != "" {
			p = cleanPfx + "/" + p
		}
	}
	return p, nil
}

func fetchObject(objPath string) ([]byte, bool, error) {
	if *cacheTTL > 0 {
		cacheMu.RLock()
		entry, ok := memCache[objPath]
		cacheMu.RUnlock()
		if ok && time.Now().Before(entry.expiresAt) {
			return entry.data, true, nil
		}
	}

	segments := strings.Split(objPath, "/")
	for i, seg := range segments {
		segments[i] = url.PathEscape(seg)
	}
	escapedPath := strings.Join(segments, "/")
	gcsURL := fmt.Sprintf("https://storage.googleapis.com/%s/%s", url.PathEscape(*bucket), escapedPath)

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, gcsURL, nil)
	if err != nil {
		return nil, false, err
	}
	req.Header.Set("User-Agent", "gcs-tftp-server/2.0")

	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, false, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return nil, false, fmt.Errorf("GCS HTTP %d for %s", resp.StatusCode, gcsURL)
	}

	data, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, false, err
	}

	if *cacheTTL > 0 {
		cacheMu.Lock()
		memCache[objPath] = cacheEntry{
			data:      data,
			expiresAt: time.Now().Add(*cacheTTL),
		}
		cacheMu.Unlock()
	}

	return data, false, nil
}

func readHandler(filename string, rf io.ReaderFrom) error {
	objPath, err := cleanObjectPath(filename)
	if err != nil {
		log.Printf("[REJECT] %q: %v", filename, err)
		return err
	}

	data, cached, err := fetchObject(objPath)
	if err != nil {
		log.Printf("[ERROR]  GET %q (object %q): %v", filename, objPath, err)
		return err
	}

	// Set RFC 2349 TransferSize (tsize) option so UEFI PXE firmware displays accurate progress
	if ot, ok := rf.(tftp.OutgoingTransfer); ok {
		ot.SetSize(int64(len(data)))
	}

	n, err := rf.ReadFrom(bytes.NewReader(data))
	if err != nil {
		log.Printf("[ABORT]  SENT %q (%d/%d bytes): %v", objPath, n, len(data), err)
		return err
	}

	log.Printf("[OK]     SENT %q (%d bytes, cached=%t)", objPath, n, cached)
	return nil
}

func main() {
	flag.Parse()

	if strings.TrimSpace(*bucket) == "" {
		log.Fatal("Error: A Google Cloud Storage bucket name must be provided via -bucket or the GCS_BUCKET environment variable.")
	}

	s := tftp.NewServer(readHandler, nil) // Read-only TFTP server (writes disabled)
	s.SetTimeout(*timeout)
	s.SetRetries(*retries)
	if *singlePort {
		s.EnableSinglePort()
	}

	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
		sig := <-sigCh
		log.Printf("Received %v, shutting down TFTP server...", sig)
		s.Shutdown()
	}()

	log.Printf("Starting GCS TFTP relay on UDP %s -> https://storage.googleapis.com/%s/%s (single-port=%t, cache-ttl=%s)",
		*listenAddr, *bucket, *prefix, *singlePort, *cacheTTL)

	if err := s.ListenAndServe(*listenAddr); err != nil {
		log.Fatalf("TFTP server exited with error: %v", err)
	}
}
