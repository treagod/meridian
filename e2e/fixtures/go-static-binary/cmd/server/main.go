package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

const homePage = `<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
    <title>Meridian recipe E2E</title>
  </head>
  <body>
    <h1>Meridian recipe E2E</h1>
    <p class="marker">Go static binary</p>
  </body>
</html>
`

func main() {
	hostname, err := os.Hostname()
	if err != nil {
		log.Fatal(err)
	}

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(homePage))
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	http.HandleFunc("/instance", func(w http.ResponseWriter, r *http.Request) {
		_, _ = fmt.Fprint(w, hostname)
	})

	http.HandleFunc("/slow", func(w http.ResponseWriter, r *http.Request) {
		seconds, err := strconv.Atoi(r.URL.Query().Get("seconds"))
		if err != nil || seconds < 1 || seconds > 120 {
			http.Error(w, "seconds must be between 1 and 120", http.StatusBadRequest)
			return
		}

		_, _ = fmt.Fprintf(w, "started:%s\n", hostname)
		if flusher, ok := w.(http.Flusher); ok {
			flusher.Flush()
		}
		time.Sleep(time.Duration(seconds) * time.Second)
		_, _ = fmt.Fprintf(w, "finished:%s\n", hostname)
	})

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
