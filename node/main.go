package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}

func readConfig(path string) (Config, error) {
	var config Config
	file, err := os.Open(path)
	if err != nil {
		return config, fmt.Errorf("open configuration: %w", err)
	}
	data, readErr := io.ReadAll(io.LimitReader(file, 65537))
	closeErr := file.Close()
	if readErr != nil {
		return config, fmt.Errorf("read configuration: %w", readErr)
	}
	if closeErr != nil {
		return config, fmt.Errorf("close configuration: %w", closeErr)
	}
	if len(data) > 65536 {
		return config, fmt.Errorf("configuration too large")
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&config); err != nil {
		return config, fmt.Errorf("decode configuration: %w", err)
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return config, fmt.Errorf("configuration must contain one JSON object")
	}
	return config, nil
}
