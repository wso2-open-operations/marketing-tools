// Copyright (c) 2026 WSO2 LLC. (https://www.wso2.com).
//
// WSO2 LLC. licenses this file to you under the Apache License,
// Version 2.0 (the "License"); you may not use this file except
// in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing,
// software distributed under the License is distributed on an
// "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
// KIND, either express or implied.  See the License for the
// specific language governing permissions and limitations
// under the License.

package handlers

import (
	"context"
	"log/slog"
	"net/http"
	"sort"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/features"
	"wso2-coin-backend/internal/models"
)

// AppConfigReader is satisfied by *repository.AppConfigRepo.
type AppConfigReader interface {
	List(ctx context.Context) ([]models.AppConfig, error)
}

// FeatureSnapshotter is the slice of *features.Resolver this handler needs.
type FeatureSnapshotter interface {
	Snapshot(ctx context.Context) map[features.Feature]features.State
}

// AppConfigHandler exposes the read-only app-configs HTTP endpoint. There is
// no write route through this API, matching the old service exactly (see
// .claude/PLAN.md).
type AppConfigHandler struct {
	configs               AppConfigReader
	features              FeatureSnapshotter
	merchantWalletAddress string
}

// NewAppConfigHandler constructs an AppConfigHandler. features may be nil, in
// which case no feature-flag rows are synthesised and the response is exactly
// what the table holds.
func NewAppConfigHandler(configs AppConfigReader, feats FeatureSnapshotter, merchantWalletAddress string) *AppConfigHandler {
	return &AppConfigHandler{configs: configs, features: feats, merchantWalletAddress: merchantWalletAddress}
}

// List handles GET /app-configs, returning every row verbatim regardless of
// what any given key means -- no filtering, no pagination.
func (h *AppConfigHandler) List(c *gin.Context) {
	configs, err := h.configs.List(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching app configs failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "internal error"})
		return
	}
	if configs == nil {
		configs = []models.AppConfig{}
	}

	configs = h.withFeatureDefaults(c.Request.Context(), configs)

	if h.merchantWalletAddress != "" {
		configs = append(configs, models.AppConfig{
			Key:   "merchantWalletAddress",
			Value: h.merchantWalletAddress,
		})
	}

	c.JSON(http.StatusOK, configs)
}

// withFeatureDefaults appends a row for every feature-flag key the table does
// not hold, so the microapp receives a complete set of flags even against a
// database that has not been seeded (or that is behind on migrations).
//
// Rows that do exist win untouched -- this only fills gaps, so it can never
// contradict what an operator set. Synthetic rows carry Go zero values in the
// four audit fields, the same way the merchantWalletAddress row already does;
// the microapp reads only key and value.
//
// Without this, a missing row means "the client falls back to whatever its
// build compiled in", and the compiled-in default of an old build is exactly
// what a flag is supposed to override. Answering from the server keeps one
// source of truth for what a feature does when nobody has configured it.
func (h *AppConfigHandler) withFeatureDefaults(ctx context.Context, configs []models.AppConfig) []models.AppConfig {
	if h.features == nil {
		return configs
	}

	present := make(map[string]struct{}, len(configs))
	for _, cfg := range configs {
		present[cfg.Key] = struct{}{}
	}

	appendIfMissing := func(key, value string) {
		if _, ok := present[key]; ok {
			return
		}
		configs = append(configs, models.AppConfig{Key: key, Value: value})
	}

	for f, state := range h.features.Snapshot(ctx) {
		enabled := "0"
		if state.Enabled {
			enabled = "1"
		}
		appendIfMissing(f.EnabledKey(), enabled)
		appendIfMissing(f.TitleKey(), state.Title)
		appendIfMissing(f.MessageKey(), state.Message)
	}

	// Snapshot is a map, so the synthesised rows arrive in a random order.
	// The SQL rows are already sorted by config_key and the microapp keys
	// the array by `key`, but an endpoint whose payload reshuffles on every
	// request defeats any response-level diffing, so sort the tail.
	sort.Slice(configs, func(i, j int) bool { return configs[i].Key < configs[j].Key })
	return configs
}
