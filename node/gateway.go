package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type gatewayVault struct {
	Config
	Paused  bool
	Revoked map[string]bool
}
type gatewayTicket struct {
	Expires time.Time
}
type gatewayRegistry struct {
	Invites map[string]gatewayTicket
	Vaults  map[string]gatewayVault
}
type gateway struct {
	slots             chan struct{}
	mu                sync.RWMutex
	registry          gatewayRegistry
	registryFailed    bool
	nodes             map[string]*Node
	pairs             pairMailboxes
	store             *Node
	origin, directory string
}

func openGateway(directory, origin string) (*gateway, error) {
	root, err := os.OpenRoot(directory)
	if err != nil {
		return nil, fmt.Errorf("open gateway volume: %w", err)
	}
	g := &gateway{slots: make(chan struct{}, 16), directory: directory, origin: origin, store: &Node{root: root}, nodes: map[string]*Node{},
		registry: gatewayRegistry{map[string]gatewayTicket{}, map[string]gatewayVault{}}}
	data, err := root.ReadFile("registry.json")
	if err != nil && !os.IsNotExist(err) {
		root.Close()
		return nil, fmt.Errorf("read gateway registry: %w", err)
	}
	if errors.Is(err, os.ErrNotExist) {
		dirs, readErr := os.ReadDir(filepath.Join(directory, "vaults"))
		if (readErr != nil && !errors.Is(readErr, os.ErrNotExist)) || len(dirs) > 0 {
			root.Close()
			return nil, fmt.Errorf("vault data exists or cannot be checked; restore registry.json")
		}
	}
	if err == nil {
		if err = json.Unmarshal(data, &g.registry); err != nil || g.registry.Vaults == nil || g.registry.Invites == nil {
			root.Close()
			return nil, fmt.Errorf("invalid gateway registry")
		}
	}
	for id, v := range g.registry.Vaults {
		if id != v.VaultID || !devicePattern.MatchString(id) || v.Revoked == nil {
			g.close()
			return nil, fmt.Errorf("invalid vault registry")
		}
		n, err := newNode(v.Config, filepath.Join(directory, "vaults", id))
		if err != nil {
			g.close()
			return nil, fmt.Errorf("restore vault: %w", err)
		}
		g.nodes[id] = n
	}
	return g, nil
}
func (g *gateway) commit(next gatewayRegistry) error {
	b, err := json.Marshal(next)
	if err != nil {
		return fmt.Errorf("encode registry: %w", err)
	}
	if err = g.store.atomicWrite("registry.json", b); err != nil {
		// A directory sync error may follow a successful rename. Reopen the
		// durable registry before accepting another registration or transfer.
		g.registryFailed = true
		return fmt.Errorf("persist registry: %w", err)
	}
	g.registry = next
	return nil
}
func (g *gateway) close() {
	g.mu.Lock()
	defer g.mu.Unlock()
	for _, n := range g.nodes {
		n.root.Close()
	}
	g.store.root.Close()
}

// Caller holds the registry write lock across persistence and the ACL swap.
func (g *gateway) saveVault(next gatewayRegistry, v gatewayVault) error {
	n, err := newNode(v.Config, filepath.Join(g.directory, "vaults", v.VaultID))
	if err != nil {
		return fmt.Errorf("prepare vault: %w", err)
	}
	if err = g.commit(next); err != nil {
		n.root.Close()
		return err
	}
	if prev := g.nodes[v.VaultID]; prev != nil {
		n.nonces = prev.nonces
		n.lastGC = prev.lastGC
		prev.root.Close()
	}
	g.nodes[v.VaultID] = n
	return nil
}
