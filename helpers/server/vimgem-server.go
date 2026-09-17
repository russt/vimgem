// Copyright (c) 2026 Russ Tremain.
// Released under the MIT License. See LICENSE file for details.

//
// vimgem-server: receives HTML via HTTP POST and opens it in the
// local default browser. Intended as a relay for headless vimgem
// instances that cannot launch a browser directly.
//
// Server opens temp files (see $TMPDIR env. setting), which are persisted
// until the server exits, at which time temporary files are discarded.
// This allows user to refresh browser, save html, etc.
//
// Usage: vimgem-server [port] [interface]
//   port defaults to 8765
//   interface defaults to localhost (127.0.0.1)
//
// Configure vimgem on headless instance with:
//   let g:ai_html_display_url = 'http://<server-host-IP>:8765'
//
// The server binds to 127.0.0.1 by default (loopback only).
// To accept connections from other machines on the LAN:
//   vimgem-server 8765 0.0.0.0
//
// BUILD INSTRUCTIONS:
//  go build vimgem-server.go
//

package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strconv"
	"sync"
	"syscall"
)

//keep track of temp files for clean up on exit:
var (
	tempFiles []string
	tempMu    sync.Mutex
)

func openBrowser(path string) error {
	var cmd string
	var args []string

	switch runtime.GOOS {
	case "darwin":
		cmd = "open"
		args = []string{path}
	case "windows":
		cmd = "cmd"
		args = []string{"/c", "start", "", path}
	default: // linux, bsd, etc.
		if _, err := exec.LookPath("xdg-open"); err == nil {
			cmd = "xdg-open"
			args = []string{path}
		} else if _, err := exec.LookPath("wslview"); err == nil {
			cmd = "wslview"
			args = []string{path}
		} else {
			return fmt.Errorf("no browser opener found (tried xdg-open, wslview)")
		}
	}

	return exec.Command(cmd, args...).Start()
}

func handler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "POST required", http.StatusMethodNotAllowed)
		return
	}

	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to read body: %v", err), http.StatusInternalServerError)
		return
	}
	defer r.Body.Close()

	// Prepend a Content-Security-Policy meta tag to block all JavaScript.
	// vimgem's generated HTML uses no JS, so this costs nothing functionally
	// but prevents execution of any malicious script in unexpected HTML.
	csp := []byte("<meta http-equiv=\"Content-Security-Policy\" content=\"script-src 'none'\">\n")
	body = append(csp, body...)

	// Write to a temp file
	f, err := os.CreateTemp("", "vimgem-*.html")
	if err != nil {
		http.Error(w, fmt.Sprintf("failed to create temp file: %v", err), http.StatusInternalServerError)
		return
	}
	defer f.Close()

	tempMu.Lock()
	tempFiles = append(tempFiles, f.Name())
	tempMu.Unlock()

	if _, err := f.Write(body); err != nil {
		http.Error(w, fmt.Sprintf("failed to write html: %v", err), http.StatusInternalServerError)
		return
	}
	f.Close()

	if err := openBrowser(f.Name()); err != nil {
		http.Error(w, fmt.Sprintf("failed to open browser: %v", err), http.StatusInternalServerError)
		return
	}

	fmt.Fprintf(w, "ok\n")
}

func main() {
	port := "8765"
	bind := "127.0.0.1"

	if len(os.Args) >= 2 {
		if _, err := strconv.Atoi(os.Args[1]); err != nil {
			fmt.Fprintf(os.Stderr, "vimgem-server: invalid port %q\n", os.Args[1])
			os.Exit(1)
		}
		port = os.Args[1]
	}
	if len(os.Args) >= 3 {
		bind = os.Args[2]
	}

	addr := bind + ":" + port
	fmt.Printf("vimgem-server: listening on %s\n", addr)

	// Clean up temp files on shutdown (SIGINT, SIGTERM)
	c := make(chan os.Signal, 1)
	signal.Notify(c, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-c
		tempMu.Lock()
		n := len(tempFiles)
		for _, path := range tempFiles {
			os.Remove(path)
		}
		tempMu.Unlock()
		fmt.Printf("\nvimgem-server: cleaned up %d temp file(s), goodbye\n", n)
		os.Exit(0)
	}()

	http.HandleFunc("/", handler)
	if err := http.ListenAndServe(addr, nil); err != nil {
		fmt.Fprintf(os.Stderr, "vimgem-server: %v\n", err)
		os.Exit(1)
	}
}
