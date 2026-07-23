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

package repository

import (
	"context"

	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/models"
)

// AppConfigRepo provides read access to the app_config table. No write path
// exists through this API, matching the old service's exposed surface
// exactly (see .claude/PLAN.md) -- population is direct-SQL-seed only.
type AppConfigRepo struct {
	pool *pgxpool.Pool
}

// NewAppConfigRepo constructs an AppConfigRepo backed by the given pool.
func NewAppConfigRepo(pool *pgxpool.Pool) *AppConfigRepo {
	return &AppConfigRepo{pool: pool}
}

// List returns every row in app_config ordered by config_key, with no
// filtering -- matches the old route exactly. Returns an empty (non-nil)
// slice, not nil, when the table has no rows. A NULL value column is
// coalesced to "" -- models.AppConfig.Value is a plain string, not a
// pointer, per .claude/PLAN.md.
func (r *AppConfigRepo) List(ctx context.Context) ([]models.AppConfig, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT config_key, COALESCE(value, ''), created_by, created_at, updated_by, updated_at
		 FROM app_config
		 ORDER BY config_key`,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	configs := make([]models.AppConfig, 0)
	for rows.Next() {
		var c models.AppConfig
		if err := rows.Scan(&c.Key, &c.Value, &c.CreatedBy, &c.CreatedOn, &c.UpdatedBy, &c.UpdatedOn); err != nil {
			return nil, err
		}
		configs = append(configs, c)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return configs, nil
}
