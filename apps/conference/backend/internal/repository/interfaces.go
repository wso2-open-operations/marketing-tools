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
	"time"

	"wso2-coin-backend/internal/models"
)

// AttendeeRepository is satisfied by *AttendeeRepo. It lets the service layer
// depend on an interface it can mock in unit tests without hitting a real DB.
type AttendeeRepository interface {
	IsRegistered(ctx context.Context, email string) (bool, error)
}

// CoinAllocationRepository is satisfied by *CoinAllocationRepo.
type CoinAllocationRepository interface {
	Exists(ctx context.Context, qrID, userUUID string) (bool, error)
	Insert(ctx context.Context, alloc models.CoinAllocation) (models.CoinAllocation, error)
	UpdateStatus(ctx context.Context, qrID, userUUID string, status models.TransactionStatus) error
	History(ctx context.Context, userUUID string) ([]models.CoinAllocationHistory, error)
	Summary(ctx context.Context, userUUID string) (models.CoinAllocationSummary, error)
}

// SessionRepository is satisfied by *SessionRepo.
type SessionRepository interface {
	GetTimeWindow(ctx context.Context, sessionID string) (start, end time.Time, err error)
}

// Compile-time assertions that the concrete repos satisfy their interfaces.
var (
	_ AttendeeRepository       = (*AttendeeRepo)(nil)
	_ CoinAllocationRepository = (*CoinAllocationRepo)(nil)
	_ SessionRepository        = (*SessionRepo)(nil)
)
