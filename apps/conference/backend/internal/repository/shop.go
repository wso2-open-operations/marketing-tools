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
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"wso2-coin-backend/internal/models"
)

// ShopRepo provides read and write access to the shop tables.
//
// These three tables -- shop_item, shop_order, shop_order_item -- are a third
// ownership category for this service. Their DDL lives in the agenda-organizer
// repo (its migrations 015-017 and 019), not here, and unlike every other shared
// table this service reads, it also *writes* to two of them. So: no CREATE TABLE
// for these in this repo's migrations, and the deployed role needs
// INSERT/UPDATE, not just SELECT (see .claude/PLAN.endpoint-gap.md).
type ShopRepo struct {
	pool *pgxpool.Pool
}

// NewShopRepo constructs a ShopRepo backed by the given pool.
func NewShopRepo(pool *pgxpool.Pool) *ShopRepo {
	return &ShopRepo{pool: pool}
}

// ErrStockShortfall is returned by Checkout when an item cannot satisfy the
// requested quantity. It names the item and the quantity actually available so
// the handler can hand the client enough to fix its own cart rather than a bare
// failure -- the client reads both fields and adjusts or drops the line.
type ErrStockShortfall struct {
	ItemID    string
	Available int
}

func (e *ErrStockShortfall) Error() string {
	return fmt.Sprintf("insufficient stock for item %s: %d available", e.ItemID, e.Available)
}

// ErrItemUnavailable is returned when a requested item id is not in the
// purchasable catalog at all -- unknown, not VISIBLE, or belonging to a
// different event.
type ErrItemUnavailable struct {
	ItemID string
}

func (e *ErrItemUnavailable) Error() string {
	return fmt.Sprintf("item %s is not available for purchase", e.ItemID)
}

// ErrPerUserLimit is returned when a line would take the caller past an item's
// max_per_user, counting everything they have already ordered for this event.
type ErrPerUserLimit struct {
	ItemID    string
	Limit     int
	Purchased int
}

func (e *ErrPerUserLimit) Error() string {
	return fmt.Sprintf("item %s is limited to %d per attendee (%d already ordered)", e.ItemID, e.Limit, e.Purchased)
}

// Shop-level sentinel errors, mapped to HTTP status codes by the handler.
var (
	// ErrShopClosed means the event's shop_closing_time has passed.
	ErrShopClosed = errors.New("the shop is closed")
	// ErrOrderNotOwned means the order exists but belongs to another user.
	ErrOrderNotOwned = errors.New("you are not allowed to confirm this order")
	// ErrOrderNotPending means the order has already left PENDING, so there is
	// nothing to confirm.
	ErrOrderNotPending = errors.New("order is not pending")
	// ErrTxHashAlreadyUsed means the transaction hash is already recorded
	// against a different order.
	ErrTxHashAlreadyUsed = errors.New("this transaction hash has already been used for another order")
)

// CurrentShopEvent returns the current conference's id and whether its shop is
// still open.
//
// "Current" is the conference_config with the latest start_date -- the same rule
// GetEvents, GetCurrentEvent and GetEventAgendas already use. A NULL
// shop_closing_time means the shop has no closing time and stays open.
//
// Returns ErrNotFound when no conference_config row exists.
func (r *ShopRepo) CurrentShopEvent(ctx context.Context) (eventID string, isOpen bool, err error) {
	var closingTime *time.Time
	queryErr := r.pool.QueryRow(ctx,
		`SELECT id, shop_closing_time
		 FROM conference_config
		 ORDER BY start_date DESC
		 LIMIT 1`,
	).Scan(&eventID, &closingTime)
	if queryErr != nil {
		if errors.Is(queryErr, pgx.ErrNoRows) {
			return "", false, ErrNotFound
		}
		return "", false, queryErr
	}
	return eventID, closingTime == nil || time.Now().Before(*closingTime), nil
}

// ListItems returns the purchasable catalog for the given event, cheapest-last
// (price DESC, matching the legacy ordering), then by name so equal-priced items
// have a stable order rather than whatever the planner returns.
//
// Only VISIBLE items are returned: HIDDEN and DELETED both exist to take an item
// out of the shop, and filtering here rather than trusting the client to do it
// means a hidden item is not merely undisplayed but unbuyable, since checkout
// resolves prices from this same predicate.
//
// event_id IS NULL rows are included. Upstream added shop_item.event_id in 019
// and backfilled it, but the column is nullable with no default, so an item
// created by any path that predates or ignores it would otherwise silently
// vanish from every event's catalog.
func (r *ShopRepo) ListItems(ctx context.Context, eventID string) ([]models.ShopItem, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT id, name, COALESCE(description, ''), price, image_url,
		        available_stock, max_per_user, category, visibility
		 FROM shop_item
		 WHERE visibility = $1
		   AND (event_id IS NULL OR event_id = $2)
		 ORDER BY price DESC, name`,
		models.ShopVisibilityVisible, eventID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	items := make([]models.ShopItem, 0)
	for rows.Next() {
		var it models.ShopItem
		if err := rows.Scan(
			&it.ID, &it.Name, &it.Description, &it.Price, &it.ImageURL,
			&it.AvailableStock, &it.MaxPerUser, &it.Category, &it.Visibility,
		); err != nil {
			return nil, err
		}
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return items, nil
}

// OrderHistory returns every order the given user has placed, newest first,
// with its lines nested.
//
// The join to shop_item is a LEFT JOIN on purpose. The legacy query inner-joined
// it, so an order line whose item had since been removed silently disappeared
// from the receipt and the order's displayed lines no longer added up to its
// total. Upstream's soft-delete (visibility='DELETED') makes that rarer but not
// impossible, and a receipt must not quietly lose a line -- so a missing item
// degrades to an empty name instead of a dropped row.
//
// Unit price comes from shop_order_item.unit_price, frozen at checkout, never
// from the item's current price.
func (r *ShopRepo) OrderHistory(ctx context.Context, userUUID, eventID string) ([]models.ShopOrder, error) {
	rows, err := r.pool.Query(ctx,
		`SELECT o.id, o.event_id, o.status, o.total_coins_amount, o.created_on,
		        o.transaction_hash,
		        o.shipping_recipient_name, o.shipping_email,
		        o.shipping_address_line1, o.shipping_address_line2,
		        o.shipping_city, o.shipping_state,
		        o.shipping_postal_code, o.shipping_country,
		        oi.item_id, oi.quantity, oi.unit_price,
		        i.name, i.description, i.image_url, i.category
		 FROM shop_order o
		 LEFT JOIN shop_order_item oi ON oi.order_id = o.id
		 LEFT JOIN shop_item i ON i.id = oi.item_id
		 WHERE o.user_uuid = $1 AND o.event_id = $2 AND o.status IN ('CONFIRMED', 'FULFILLED')
		 ORDER BY o.created_on DESC, o.id, oi.item_id`,
		userUUID,
		eventID,
	)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	order := make([]string, 0)
	byID := make(map[string]*models.ShopOrder)

	for rows.Next() {
		var (
			orderID     string
			eventID     *string
			status      string
			total       float64
			createdOn   time.Time
			txHash      *string
			recipient   string
			email       string
			addr1       string
			addr2       *string
			city        string
			state       *string
			postal      *string
			country     string
			itemID      *string
			quantity    *int
			unitPrice   *float64
			itemName    *string
			itemDesc    *string
			itemImage   *string
			itemCategry *string
		)

		if err := rows.Scan(
			&orderID, &eventID, &status, &total, &createdOn,
			&txHash,
			&recipient, &email,
			&addr1, &addr2,
			&city, &state,
			&postal, &country,
			&itemID, &quantity, &unitPrice,
			&itemName, &itemDesc, &itemImage, &itemCategry,
		); err != nil {
			return nil, err
		}

		o, ok := byID[orderID]
		if !ok {
			o = &models.ShopOrder{
				OrderID:               orderID,
				Status:                status,
				Total:                 total,
				Date:                  createdOn,
				Items:                 make([]models.ShopOrderLine, 0),
				ShippingRecipientName: recipient,
				ShippingEmail:         email,
				ShippingAddressLine1:  addr1,
				ShippingCity:          city,
				ShippingCountry:       country,
			}
			if eventID != nil {
				o.EventID = *eventID
			}
			if txHash != nil {
				o.TxHash = *txHash
			}
			if addr2 != nil {
				o.ShippingAddressLine2 = *addr2
			}
			if state != nil {
				o.ShippingState = *state
			}
			if postal != nil {
				o.ShippingPostalCode = *postal
			}
			byID[orderID] = o
			order = append(order, orderID)
		}

		// An order with no lines at all yields one all-NULL line row from the
		// LEFT JOIN; keep the order, skip the phantom line.
		if itemID == nil {
			continue
		}

		line := models.ShopOrderLine{
			ItemID:   *itemID,
			ID:       *itemID,
			Quantity: derefInt(quantity),
		}
		if unitPrice != nil {
			line.Price = *unitPrice
			line.PriceAtPurchase = *unitPrice
		}
		if itemName != nil {
			line.Name = *itemName
		}
		if itemDesc != nil {
			line.Description = *itemDesc
		}
		if itemImage != nil {
			line.ImageURL = *itemImage
		}
		if itemCategry != nil {
			line.Category = *itemCategry
		}
		o.Items = append(o.Items, line)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	result := make([]models.ShopOrder, 0, len(order))
	for _, id := range order {
		result = append(result, *byID[id])
	}
	return result, nil
}

func derefInt(v *int) int {
	if v == nil {
		return 0
	}
	return *v
}

// CheckoutParams is everything Checkout needs beyond the request itself.
type CheckoutParams struct {
	OrderID  string
	UserUUID string
	Email    string
	EventID  string
	Request  models.CheckoutRequest
}

// Checkout creates a PENDING order and decrements stock, atomically.
//
// This is the only place in this service that writes to a shared table inside a
// transaction, and every part of it has to succeed together: the order row, one
// line per item, and one conditional stock decrement per item. If any single
// item cannot be satisfied the whole order is rolled back, so a partially-paid
// basket can never exist.
//
// Returns the total it computed. That total is derived here from live
// shop_item.price rows -- the client's own totalCost is never consulted -- which
// is what stops a caller naming its own price.
//
// Idempotency: a replayed (user_uuid, idempotency_key) returns the existing
// order id and its total with no second write. The legacy service had no
// idempotency at all, so an impatient double-click created two orders and
// double-decremented stock. Upstream added the column and its UNIQUE constraint
// for exactly this; the pre-check below handles the common replay, and the
// unique-violation branch handles two truly concurrent replays where both pass
// the pre-check.
func (r *ShopRepo) Checkout(ctx context.Context, p CheckoutParams) (orderID string, total float64, err error) {
	if p.Request.IdempotencyKey != "" {
		existingID, existingTotal, found, lookupErr := r.orderByIdempotencyKey(ctx, p.UserUUID, p.Request.IdempotencyKey)
		if lookupErr != nil {
			return "", 0, lookupErr
		}
		if found {
			return existingID, existingTotal, nil
		}
	}

	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return "", 0, err
	}
	// Rollback is a no-op once the tx has committed, so this is safe
	// unconditionally and guarantees no path leaks an open transaction.
	defer func() { _ = tx.Rollback(ctx) }()

	// Lock the requested catalog rows in a deterministic order (by id) before
	// touching anything. Two concurrent carts holding the same two items in
	// opposite orders would otherwise be able to deadlock each other.
	ids := make([]string, 0, len(p.Request.Items))
	for _, it := range p.Request.Items {
		ids = append(ids, it.ID)
	}

	rows, err := tx.Query(ctx,
		`SELECT id, price, available_stock, max_per_user
		 FROM shop_item
		 WHERE id = ANY($1)
		   AND visibility = $2
		   AND (event_id IS NULL OR event_id = $3)
		 ORDER BY id
		 FOR UPDATE`,
		ids, models.ShopVisibilityVisible, p.EventID,
	)
	if err != nil {
		return "", 0, err
	}

	type catalogRow struct {
		price      float64
		stock      int
		maxPerUser *int
	}
	catalog := make(map[string]catalogRow, len(ids))
	for rows.Next() {
		var id string
		var row catalogRow
		if scanErr := rows.Scan(&id, &row.price, &row.stock, &row.maxPerUser); scanErr != nil {
			rows.Close()
			return "", 0, scanErr
		}
		catalog[id] = row
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return "", 0, err
	}

	// Every requested item must be in the purchasable catalog, and stock and
	// per-user caps are checked before a single write, so the common rejection
	// costs no inserts.
	totalScaled := int64(0)
	for _, want := range p.Request.Items {
		row, ok := catalog[want.ID]
		if !ok {
			return "", 0, &ErrItemUnavailable{ItemID: want.ID}
		}
		if row.stock < want.Quantity {
			return "", 0, &ErrStockShortfall{ItemID: want.ID, Available: row.stock}
		}
		if row.maxPerUser != nil && *row.maxPerUser > 0 {
			purchased, countErr := r.purchasedQuantity(ctx, tx, p.UserUUID, p.EventID, want.ID)
			if countErr != nil {
				return "", 0, countErr
			}
			if purchased+want.Quantity > *row.maxPerUser {
				return "", 0, &ErrPerUserLimit{
					ItemID:    want.ID,
					Limit:     *row.maxPerUser,
					Purchased: purchased,
				}
			}
		}
		totalScaled += models.ScaleCoins(row.price) * int64(want.Quantity)
	}
	total = float64(totalScaled) / 10000

	var idempotencyKey *string
	if p.Request.IdempotencyKey != "" {
		idempotencyKey = &p.Request.IdempotencyKey
	}

	_, err = tx.Exec(ctx,
		`INSERT INTO shop_order (
		     id, user_uuid, event_id, status, transaction_hash, total_coins_amount,
		     created_by, updated_by, idempotency_key,
		     shipping_recipient_name, shipping_email,
		     shipping_address_line1, shipping_address_line2,
		     shipping_city, shipping_state,
		     shipping_postal_code, shipping_country
		 ) VALUES ($1, $2, $3, $4, NULL, $5, $6, $6, $7,
		           $8, $9, $10, $11, $12, $13, $14, $15)`,
		p.OrderID, p.UserUUID, p.EventID, models.ShopOrderStatusPending, total,
		p.Email, idempotencyKey,
		p.Request.ShippingRecipientName, p.Request.ShippingEmail,
		p.Request.ShippingAddressLine1, nullableText(p.Request.ShippingAddressLine2),
		p.Request.ShippingCity, nullableText(p.Request.ShippingState),
		nullableText(p.Request.ShippingPostalCode), p.Request.ShippingCountry,
	)
	if err != nil {
		// A concurrent replay of the same idempotency key won the race to
		// insert. That is a success for this caller too: return the order the
		// other request created rather than an error.
		if isUniqueViolation(err) && idempotencyKey != nil {
			existingID, existingTotal, found, lookupErr := r.orderByIdempotencyKey(ctx, p.UserUUID, *idempotencyKey)
			if lookupErr == nil && found {
				return existingID, existingTotal, nil
			}
		}
		return "", 0, err
	}

	for _, want := range p.Request.Items {
		row := catalog[want.ID]

		if _, err = tx.Exec(ctx,
			`INSERT INTO shop_order_item (order_id, item_id, quantity, unit_price)
			 VALUES ($1, $2, $3, $4)`,
			p.OrderID, want.ID, want.Quantity, row.price,
		); err != nil {
			return "", 0, err
		}

		// Guarded decrement. The FOR UPDATE above already serialises concurrent
		// carts for these rows, so this cannot lose a race -- but the
		// available_stock >= $2 predicate stays as the invariant that makes
		// negative stock unrepresentable regardless of how it is called.
		tag, execErr := tx.Exec(ctx,
			`UPDATE shop_item
			 SET available_stock = available_stock - $2
			 WHERE id = $1 AND available_stock >= $2`,
			want.ID, want.Quantity,
		)
		if execErr != nil {
			return "", 0, execErr
		}
		if tag.RowsAffected() == 0 {
			return "", 0, &ErrStockShortfall{ItemID: want.ID, Available: row.stock}
		}
	}

	if err = tx.Commit(ctx); err != nil {
		return "", 0, err
	}
	return p.OrderID, total, nil
}

// orderByIdempotencyKey looks up an order previously created with this
// (user, key) pair.
func (r *ShopRepo) orderByIdempotencyKey(ctx context.Context, userUUID, key string) (orderID string, total float64, found bool, err error) {
	queryErr := r.pool.QueryRow(ctx,
		`SELECT id, total_coins_amount
		 FROM shop_order
		 WHERE user_uuid = $1 AND idempotency_key = $2`,
		userUUID, key,
	).Scan(&orderID, &total)
	if queryErr != nil {
		if errors.Is(queryErr, pgx.ErrNoRows) {
			return "", 0, false, nil
		}
		return "", 0, false, queryErr
	}
	return orderID, total, true, nil
}

// purchasedQuantity counts how many units of one item a user has already
// ordered for an event, for the max_per_user check.
//
// FAILED and EXPIRED orders are excluded: both are terminal reversals whose
// stock the organizer's admin path has already restored, so continuing to count
// them against the cap would permanently consume a user's allowance for a
// purchase that never completed. Everything else counts, PENDING included -- an
// unconfirmed order is still holding its stock.
func (r *ShopRepo) purchasedQuantity(ctx context.Context, tx pgx.Tx, userUUID, eventID, itemID string) (int, error) {
	var total *int
	err := tx.QueryRow(ctx,
		`SELECT SUM(oi.quantity)
		 FROM shop_order o
		 JOIN shop_order_item oi ON oi.order_id = o.id
		 WHERE o.user_uuid = $1
		   AND oi.item_id = $2
		   AND (o.event_id IS NULL OR o.event_id = $3)
		   AND o.status NOT IN ($4, $5)`,
		userUUID, itemID, eventID,
		models.ShopOrderStatusFailed, models.ShopOrderStatusExpired,
	).Scan(&total)
	if err != nil {
		return 0, err
	}
	if total == nil {
		return 0, nil
	}
	return *total, nil
}

// PendingOrder is the subset of an order the confirm flow needs.
type PendingOrder struct {
	ID       string
	UserUUID string
	Status   string
	Total    float64
}

// ConfirmOrder flips a PENDING order to CONFIRMED and records its transaction
// hash, after verify has accepted the on-chain payment.
//
// The order row is locked FOR UPDATE and re-read inside the transaction, and
// verify runs while that lock is held. The legacy service did its
// ownership/status/hash-reuse checks and its blockchain call entirely outside any
// transaction, leaving a window where two concurrent confirms with two different
// hashes could both pass every check; the loser then got a 500 from an
// UPDATE that silently affected no rows. Holding the row for the duration closes
// that window, so a second confirm sees CONFIRMED and gets a clean
// ErrOrderNotPending instead.
//
// verify is called with the order's authoritative stored total, not anything
// supplied by the caller.
func (r *ShopRepo) ConfirmOrder(
	ctx context.Context,
	orderID, userUUID, txHash, updatedBy string,
	verify func(ctx context.Context, expectedTotal float64) error,
) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback(ctx) }()

	var order PendingOrder
	err = tx.QueryRow(ctx,
		`SELECT id, user_uuid, status, total_coins_amount
		 FROM shop_order
		 WHERE id = $1
		 FOR UPDATE`,
		orderID,
	).Scan(&order.ID, &order.UserUUID, &order.Status, &order.Total)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		return err
	}

	if order.UserUUID != userUUID {
		return ErrOrderNotOwned
	}
	if order.Status != models.ShopOrderStatusPending {
		return ErrOrderNotPending
	}

	// The hash must not already be bound to a different order. Checking inside
	// the transaction means the UNIQUE constraint on transaction_hash becomes a
	// backstop rather than the primary control, so the caller gets a meaningful
	// error instead of a constraint violation.
	var existingID string
	err = tx.QueryRow(ctx,
		`SELECT id FROM shop_order WHERE transaction_hash = $1`,
		txHash,
	).Scan(&existingID)
	switch {
	case err == nil && existingID != orderID:
		return ErrTxHashAlreadyUsed
	case err != nil && !errors.Is(err, pgx.ErrNoRows):
		return err
	}

	if err := verify(ctx, order.Total); err != nil {
		return err
	}

	tag, err := tx.Exec(ctx,
		`UPDATE shop_order
		 SET status = $2, transaction_hash = $3, updated_by = $4, updated_on = NOW()
		 WHERE id = $1 AND status = $5`,
		orderID, models.ShopOrderStatusConfirmed, txHash, updatedBy,
		models.ShopOrderStatusPending,
	)
	if err != nil {
		if isUniqueViolation(err) {
			return ErrTxHashAlreadyUsed
		}
		return err
	}
	if tag.RowsAffected() == 0 {
		// Unreachable while the row lock is held, since the status was just
		// re-read under it. Kept as an explicit, correct answer rather than a
		// silent success if that ever stops being true.
		return ErrOrderNotPending
	}

	return tx.Commit(ctx)
}

// nullableText maps an empty optional string to a NULL, so an omitted address
// line is stored as NULL rather than an empty string. The columns are nullable
// precisely to record "not provided".
func nullableText(v string) *string {
	if v == "" {
		return nil
	}
	return &v
}

// isUniqueViolation reports whether err is a Postgres unique-constraint
// violation, reusing the SQLSTATE constant declared for coin allocations.
func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == pgUniqueViolation
}

// MarkStaleOrders expires PENDING orders older than timeoutMinutes and restores their stock.
func (r *ShopRepo) MarkStaleOrders(ctx context.Context, timeoutMinutes int) (int, error) {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return 0, fmt.Errorf("begin tx: %w", err)
	}
	defer func() { _ = tx.Rollback(ctx) }()

	// Fetch orders to cancel to restore their stock
	selectQuery := `
		SELECT id FROM shop_order
		WHERE status = 'PENDING' 
		  AND created_on < NOW() - INTERVAL '1 minute' * $1
		FOR UPDATE SKIP LOCKED
	`
	rows, err := tx.Query(ctx, selectQuery, timeoutMinutes)
	if err != nil {
		return 0, fmt.Errorf("select stale orders: %w", err)
	}
	var staleOrderIDs []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return 0, fmt.Errorf("scan stale order id: %w", err)
		}
		staleOrderIDs = append(staleOrderIDs, id)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return 0, fmt.Errorf("rows iterate error: %w", err)
	}

	if len(staleOrderIDs) == 0 {
		return 0, nil
	}

	// Restore stock for these orders
	for _, orderID := range staleOrderIDs {
		// Cancel the order
		tag, err := tx.Exec(ctx, `UPDATE shop_order SET status = 'EXPIRED', updated_on = NOW(), updated_by = 'SYSTEM' WHERE id = $1 AND status = 'PENDING'`, orderID)
		if err != nil {
			return 0, fmt.Errorf("update stale order %s: %w", orderID, err)
		}
		if tag.RowsAffected() == 0 {
			continue
		}

		// Restore stock
		_, err = tx.Exec(ctx, `
			UPDATE shop_item i
			SET available_stock = i.available_stock + oi.quantity
			FROM shop_order_item oi
			WHERE i.id = oi.item_id AND oi.order_id = $1
		`, orderID)
		if err != nil {
			return 0, fmt.Errorf("restore stock for stale order %s: %w", orderID, err)
		}
	}

	if err := tx.Commit(ctx); err != nil {
		return 0, fmt.Errorf("commit stale orders tx: %w", err)
	}
	return len(staleOrderIDs), nil
}
