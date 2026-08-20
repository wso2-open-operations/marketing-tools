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
	"database/sql"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// PoolConfig tunes the Postgres connection pool, mirroring the original
// Ballerina service's sql:ConnectionPool config (maxOpenConnections,
// maxConnectionLifeTime, minIdleConnections).
type PoolConfig struct {
	MaxOpenConns    int
	ConnMaxLifetime time.Duration
	// MaxIdleConns mirrors minIdleConnections. Go's database/sql only
	// exposes a maximum idle pool size, not a maintained minimum — this
	// caps idle connections at the given count rather than guaranteeing
	// that many stay open, unlike the original driver's pool.
	MaxIdleConns int
}

// Connect opens a Postgres connection pool (via pgx's database/sql driver),
// applies the given pool tuning, and verifies connectivity.
func Connect(ctx context.Context, dsn string, pool PoolConfig) (*sql.DB, error) {
	db, err := sql.Open("pgx", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(pool.MaxOpenConns)
	db.SetConnMaxLifetime(pool.ConnMaxLifetime)
	db.SetMaxIdleConns(pool.MaxIdleConns)
	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, err
	}
	return db, nil
}
