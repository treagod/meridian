package main

import (
	"log"
	"net/http"
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

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
