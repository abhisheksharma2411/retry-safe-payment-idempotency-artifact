package core

import (
	"bufio"
	"fmt"
	"os"
	"strconv"
	"strings"
)

func LoadProfile(path string) (ProviderProfile, error) {
	file, err := os.Open(path)
	if err != nil {
		return ProviderProfile{}, err
	}
	defer file.Close()

	profile := ProviderProfile{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		parts := strings.SplitN(line, ":", 2)
		if len(parts) != 2 {
			return ProviderProfile{}, fmt.Errorf("invalid profile line: %q", line)
		}
		key := strings.TrimSpace(parts[0])
		value := strings.TrimSpace(parts[1])
		switch key {
		case "name":
			profile.Name = value
		case "scope":
			profile.Scope = value
		case "deduplication":
			profile.Deduplication = value == "true"
		case "authoritative_lookup":
			profile.AuthoritativeLookup = value == "true"
		case "async_settlement":
			profile.AsyncSettlement = value == "true"
		case "provider_retention_steps":
			n, err := strconv.Atoi(value)
			if err != nil {
				return ProviderProfile{}, err
			}
			profile.ProviderRetention = n
		default:
			return ProviderProfile{}, fmt.Errorf("unsupported profile key %q", key)
		}
	}
	if err := scanner.Err(); err != nil {
		return ProviderProfile{}, err
	}
	return profile, nil
}
