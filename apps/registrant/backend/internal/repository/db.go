// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com). All Rights Reserved.
//
// This software is the property of WSO2 LLC. and its suppliers, if any.
// Dissemination of any information or reproduction of any material contained
// herein in any form is strictly forbidden, unless permitted by WSO2 expressly.
// You may not alter or remove any copyright or other notice from copies of this content.

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
