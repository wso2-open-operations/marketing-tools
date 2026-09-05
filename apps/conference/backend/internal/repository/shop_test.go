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

//go:build integration

package repository

import (
	"context"
	"errors"
	"testing"
	"time"

	"wso2-coin-backend/internal/models"
)

// shopFixture owns an isolated conference plus the shop rows a test creates, and
// deletes exactly those rows afterwards. It never touches unrelated rows in these
// shared tables.
type shopFixture struct {
	eventID string
	userID  string
}

func newShopFixture(t *testing.T, ctx context.Context, closingTime *time.Time) *shopFixture {
	t.Helper()

	// start_date is one day past whatever is currently latest (floored well into
	// the future) rather than a fixed literal, so this fixture is unambiguously
	// "the current conference". A fixed date tied with any leftover or
	// concurrently-created fixture, and CurrentShopEvent's id tiebreak then
	// resolved the tie to a stranger's row.
	var eventID string
	err := testDB.QueryRow(ctx,
		`INSERT INTO conference_config (name, start_date, timezone, shop_closing_time)
		 SELECT $1, GREATEST(COALESCE(MAX(start_date), DATE '2099-06-01'), DATE '2099-06-01') + 1,
		        'UTC', $2
		 FROM conference_config
		 RETURNING id`,
		"TDD Shop Conference", closingTime,
	).Scan(&eventID)
	if err != nil {
		t.Fatalf("failed to insert conference_config: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", eventID)
	})

	return &shopFixture{eventID: eventID, userID: newUUID()}
}

// insertItem seeds a catalog row. visibility defaults to VISIBLE when empty.
func (f *shopFixture) insertItem(t *testing.T, ctx context.Context, price float64, stock int, visibility string, maxPerUser *int) string {
	t.Helper()
	if visibility == "" {
		visibility = models.ShopVisibilityVisible
	}
	id := "item-" + newUUID()
	_, err := testDB.Exec(ctx,
		`INSERT INTO shop_item (id, name, description, price, image_url, available_stock,
		     category, max_per_user, visibility, event_id)
		 VALUES ($1, $2, 'A test item', $3, 'https://example.com/i.png', $4, 'merch', $5, $6, $7)`,
		id, "Item "+id, price, stock, maxPerUser, visibility, f.eventID,
	)
	if err != nil {
		t.Fatalf("failed to insert shop_item: %v", err)
	}
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM shop_order_item WHERE item_id = $1", id)
		_, _ = testDB.Exec(context.Background(), "DELETE FROM shop_item WHERE id = $1", id)
	})
	return id
}

func (f *shopFixture) cleanupOrder(t *testing.T, orderID string) {
	t.Cleanup(func() {
		_, _ = testDB.Exec(context.Background(), "DELETE FROM shop_order_item WHERE order_id = $1", orderID)
		_, _ = testDB.Exec(context.Background(), "DELETE FROM shop_order WHERE id = $1", orderID)
	})
}

func (f *shopFixture) checkoutParams(orderID string, items ...models.CheckoutItem) CheckoutParams {
	return CheckoutParams{
		OrderID:  orderID,
		UserUUID: f.userID,
		Email:    "shopper@example.com",
		EventID:  f.eventID,
		Request: models.CheckoutRequest{
			Items:                 items,
			ShippingRecipientName: "Jane Doe",
			ShippingEmail:         "jane@example.com",
			ShippingAddressLine1:  "1 Main St",
			ShippingCity:          "Colombo",
			ShippingCountry:       "LK",
		},
	}
}

func stockOf(t *testing.T, ctx context.Context, itemID string) int {
	t.Helper()
	var stock int
	if err := testDB.QueryRow(ctx, "SELECT available_stock FROM shop_item WHERE id = $1", itemID).Scan(&stock); err != nil {
		t.Fatalf("failed to read stock: %v", err)
	}
	return stock
}

func intPtr(v int) *int { return &v }

func TestShopRepo_CurrentShopEvent_OpenWhenNoClosingTime(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	eventID, isOpen, err := repo.CurrentShopEvent(ctx)
	if err != nil {
		t.Fatalf("CurrentShopEvent returned error: %v", err)
	}
	if eventID != fixture.eventID {
		t.Errorf("eventID = %q, want the latest-start_date conference %q", eventID, fixture.eventID)
	}
	if !isOpen {
		t.Error("isOpen = false; a NULL shop_closing_time means the shop never closes")
	}
}

func TestShopRepo_CurrentShopEvent_ClosedAfterClosingTime(t *testing.T) {
	ctx := context.Background()
	past := time.Now().Add(-time.Hour)
	newShopFixture(t, ctx, &past)
	repo := NewShopRepo(testDB)

	_, isOpen, err := repo.CurrentShopEvent(ctx)
	if err != nil {
		t.Fatalf("CurrentShopEvent returned error: %v", err)
	}
	if isOpen {
		t.Error("isOpen = true after the closing time passed")
	}
}

// The shop must resolve the same "current conference" as every other route.
// Without the id tiebreak two conferences sharing a start_date leave the planner
// to pick, so GET /shops/items could serve one conference's catalog while
// GET /events/current names another -- and the catalog then reads as empty.
//
// The expectation is computed with an independent formulation rather than from
// this test's own two fixtures: these are shared staging tables and another
// suite may hold a conference row of its own at the same start_date.
func TestShopRepo_CurrentShopEvent_BreaksStartDateTiesOnID(t *testing.T) {
	ctx := context.Background()

	// Two conferences deliberately sharing one start_date, both at the latest.
	var tieDate time.Time
	if err := testDB.QueryRow(ctx,
		`SELECT GREATEST(COALESCE(MAX(start_date), DATE '2099-06-01'), DATE '2099-06-01') + 1
		 FROM conference_config`,
	).Scan(&tieDate); err != nil {
		t.Fatalf("failed to compute a tie date: %v", err)
	}
	for i := 0; i < 2; i++ {
		var id string
		if err := testDB.QueryRow(ctx,
			`INSERT INTO conference_config (name, start_date, timezone)
			 VALUES ('TDD Shop Tie', $1, 'UTC') RETURNING id`, tieDate,
		).Scan(&id); err != nil {
			t.Fatalf("failed to insert tied conference_config: %v", err)
		}
		t.Cleanup(func() {
			_, _ = testDB.Exec(context.Background(), "DELETE FROM conference_config WHERE id = $1", id)
		})
	}

	// Computed with an independent formulation, not from this test's own rows:
	// these are shared staging tables.
	var want string
	if err := testDB.QueryRow(ctx,
		`SELECT MAX(id::text) FROM conference_config
		 WHERE start_date = (SELECT MAX(start_date) FROM conference_config)`,
	).Scan(&want); err != nil {
		t.Fatalf("failed to compute the expected current conference: %v", err)
	}

	eventID, _, err := NewShopRepo(testDB).CurrentShopEvent(ctx)
	if err != nil {
		t.Fatalf("CurrentShopEvent returned error: %v", err)
	}
	if eventID != want {
		t.Errorf("eventID = %q, want the highest id at the latest start_date %q", eventID, want)
	}

	// The real invariant: it must agree with GET /events/current.
	current, err := NewEventRepo(testDB, 5, time.UTC, "UTC").GetCurrentEvent(ctx)
	if err != nil {
		t.Fatalf("GetCurrentEvent returned error: %v", err)
	}
	if eventID != current.ID {
		t.Errorf("CurrentShopEvent = %q but GetCurrentEvent = %q; the two must never disagree", eventID, current.ID)
	}
}

// A hidden item must be invisible in the catalog, not merely undisplayed by the
// client -- the same predicate gates checkout.
func TestShopRepo_ListItems_ExcludesNonVisible(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	visible := fixture.insertItem(t, ctx, 10, 5, models.ShopVisibilityVisible, nil)
	hidden := fixture.insertItem(t, ctx, 20, 5, models.ShopVisibilityHidden, nil)
	deleted := fixture.insertItem(t, ctx, 30, 5, models.ShopVisibilityDeleted, nil)

	items, err := repo.ListItems(ctx, fixture.eventID)
	if err != nil {
		t.Fatalf("ListItems returned error: %v", err)
	}

	seen := map[string]bool{}
	for _, it := range items {
		seen[it.ID] = true
	}
	if !seen[visible] {
		t.Error("a VISIBLE item was not listed")
	}
	if seen[hidden] {
		t.Error("a HIDDEN item was listed")
	}
	if seen[deleted] {
		t.Error("a DELETED item was listed")
	}
}

func TestShopRepo_Checkout_CreatesOrderAndDecrementsStock(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 12.5, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)

	gotID, total, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 2}))
	if err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}
	if gotID != orderID {
		t.Errorf("order id = %q, want %q", gotID, orderID)
	}
	if models.ScaleCoins(total) != models.ScaleCoins(25) {
		t.Errorf("total = %v, want 25 (2 x 12.5)", total)
	}
	if got := stockOf(t, ctx, item); got != 8 {
		t.Errorf("stock = %d, want 8", got)
	}

	var status string
	var storedTotal float64
	var lineQty int
	var unitPrice float64
	if err := testDB.QueryRow(ctx,
		`SELECT o.status, o.total_coins_amount, oi.quantity, oi.unit_price
		 FROM shop_order o JOIN shop_order_item oi ON oi.order_id = o.id
		 WHERE o.id = $1`, orderID,
	).Scan(&status, &storedTotal, &lineQty, &unitPrice); err != nil {
		t.Fatalf("failed to read back order: %v", err)
	}
	if status != models.ShopOrderStatusPending {
		t.Errorf("status = %q, want PENDING", status)
	}
	if models.ScaleCoins(storedTotal) != models.ScaleCoins(25) {
		t.Errorf("stored total = %v, want 25", storedTotal)
	}
	if lineQty != 2 {
		t.Errorf("line quantity = %d, want 2", lineQty)
	}
	// The unit price must be frozen at checkout, so a later catalog price change
	// cannot rewrite history.
	if models.ScaleCoins(unitPrice) != models.ScaleCoins(12.5) {
		t.Errorf("unit_price = %v, want the 12.5 frozen at checkout", unitPrice)
	}
}

// The price-tampering defence: whatever total the client claims, the server
// charges what the catalog says.
func TestShopRepo_Checkout_IgnoresClientSuppliedTotal(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 100, 5, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)

	params := fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 1})
	params.Request.TotalCost = 1 // a caller naming its own price

	_, total, err := repo.Checkout(ctx, params)
	if err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}
	if models.ScaleCoins(total) != models.ScaleCoins(100) {
		t.Errorf("total = %v, want 100 recomputed from the catalog, not the claimed 1", total)
	}
}

// A shortfall on any line must roll the whole basket back: no order row, and no
// stock taken from the lines that could have been satisfied.
func TestShopRepo_Checkout_ShortfallRollsBackEverything(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	plentiful := fixture.insertItem(t, ctx, 10, 10, "", nil)
	scarce := fixture.insertItem(t, ctx, 10, 1, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)

	_, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID,
		models.CheckoutItem{ID: plentiful, Quantity: 2},
		models.CheckoutItem{ID: scarce, Quantity: 5},
	))

	var shortfall *ErrStockShortfall
	if !errors.As(err, &shortfall) {
		t.Fatalf("err = %v, want ErrStockShortfall", err)
	}
	if shortfall.ItemID != scarce {
		t.Errorf("shortfall names %q, want the scarce item %q", shortfall.ItemID, scarce)
	}
	if shortfall.Available != 1 {
		t.Errorf("available = %d, want 1", shortfall.Available)
	}

	if got := stockOf(t, ctx, plentiful); got != 10 {
		t.Errorf("the satisfiable item's stock = %d, want 10 (rolled back)", got)
	}
	if got := stockOf(t, ctx, scarce); got != 1 {
		t.Errorf("the scarce item's stock = %d, want 1 (untouched)", got)
	}

	var exists bool
	if err := testDB.QueryRow(ctx, "SELECT EXISTS (SELECT 1 FROM shop_order WHERE id = $1)", orderID).Scan(&exists); err != nil {
		t.Fatalf("failed to check order existence: %v", err)
	}
	if exists {
		t.Error("an order row survived a rolled-back checkout")
	}
}

// The legacy service had no idempotency, so an impatient double-click created two
// orders and took stock twice.
func TestShopRepo_Checkout_ReplayedIdempotencyKeyReturnsSameOrder(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 10, 10, "", nil)
	firstOrder := "ORD-" + newUUID()
	secondOrder := "ORD-" + newUUID()
	fixture.cleanupOrder(t, firstOrder)
	fixture.cleanupOrder(t, secondOrder)

	key := "idem-" + newUUID()

	params := fixture.checkoutParams(firstOrder, models.CheckoutItem{ID: item, Quantity: 3})
	params.Request.IdempotencyKey = key
	gotFirst, totalFirst, err := repo.Checkout(ctx, params)
	if err != nil {
		t.Fatalf("first Checkout returned error: %v", err)
	}

	// Same key, a fresh order id: a retry of the same logical request.
	replay := fixture.checkoutParams(secondOrder, models.CheckoutItem{ID: item, Quantity: 3})
	replay.Request.IdempotencyKey = key
	gotSecond, totalSecond, err := repo.Checkout(ctx, replay)
	if err != nil {
		t.Fatalf("replayed Checkout returned error: %v", err)
	}

	if gotSecond != gotFirst {
		t.Errorf("replay created order %q, want the original %q", gotSecond, gotFirst)
	}
	if models.ScaleCoins(totalSecond) != models.ScaleCoins(totalFirst) {
		t.Errorf("replay total = %v, want the original %v", totalSecond, totalFirst)
	}
	if got := stockOf(t, ctx, item); got != 7 {
		t.Errorf("stock = %d, want 7 -- the replay decremented stock a second time", got)
	}
}

// A distinct key from the same user is a genuinely new order, not a replay.
func TestShopRepo_Checkout_DifferentKeyCreatesSecondOrder(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 10, 10, "", nil)
	first := "ORD-" + newUUID()
	second := "ORD-" + newUUID()
	fixture.cleanupOrder(t, first)
	fixture.cleanupOrder(t, second)

	p1 := fixture.checkoutParams(first, models.CheckoutItem{ID: item, Quantity: 1})
	p1.Request.IdempotencyKey = "idem-" + newUUID()
	if _, _, err := repo.Checkout(ctx, p1); err != nil {
		t.Fatalf("first Checkout returned error: %v", err)
	}

	p2 := fixture.checkoutParams(second, models.CheckoutItem{ID: item, Quantity: 1})
	p2.Request.IdempotencyKey = "idem-" + newUUID()
	gotID, _, err := repo.Checkout(ctx, p2)
	if err != nil {
		t.Fatalf("second Checkout returned error: %v", err)
	}
	if gotID != second {
		t.Errorf("order id = %q, want a new order %q", gotID, second)
	}
	if got := stockOf(t, ctx, item); got != 8 {
		t.Errorf("stock = %d, want 8 (two separate purchases)", got)
	}
}

// max_per_user is enforced server-side. The client disables its own "add" button,
// but that is trivially bypassable.
func TestShopRepo_Checkout_EnforcesMaxPerUserAcrossOrders(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 10, 100, "", intPtr(3))
	first := "ORD-" + newUUID()
	second := "ORD-" + newUUID()
	fixture.cleanupOrder(t, first)
	fixture.cleanupOrder(t, second)

	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(first, models.CheckoutItem{ID: item, Quantity: 2})); err != nil {
		t.Fatalf("first Checkout returned error: %v", err)
	}

	// 2 already ordered + 2 more would exceed the cap of 3.
	_, _, err := repo.Checkout(ctx, fixture.checkoutParams(second, models.CheckoutItem{ID: item, Quantity: 2}))

	var limit *ErrPerUserLimit
	if !errors.As(err, &limit) {
		t.Fatalf("err = %v, want ErrPerUserLimit", err)
	}
	if limit.Limit != 3 || limit.Purchased != 2 {
		t.Errorf("limit = %d purchased = %d, want 3 and 2", limit.Limit, limit.Purchased)
	}
	if got := stockOf(t, ctx, item); got != 98 {
		t.Errorf("stock = %d, want 98 -- the over-cap order took stock", got)
	}
}

// A cap counts a prior purchase up to the cap and no further.
func TestShopRepo_Checkout_AllowsPurchaseUpToMaxPerUser(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 10, 100, "", intPtr(3))
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)

	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 3})); err != nil {
		t.Fatalf("a purchase exactly at the cap was rejected: %v", err)
	}
}

// A hidden item must not be purchasable even if a client knows its id.
func TestShopRepo_Checkout_RejectsHiddenItem(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	hidden := fixture.insertItem(t, ctx, 10, 10, models.ShopVisibilityHidden, nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)

	_, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: hidden, Quantity: 1}))

	var unavailable *ErrItemUnavailable
	if !errors.As(err, &unavailable) {
		t.Fatalf("err = %v, want ErrItemUnavailable", err)
	}
	if got := stockOf(t, ctx, hidden); got != 10 {
		t.Errorf("stock = %d, want 10 untouched", got)
	}
}

func TestShopRepo_Checkout_RejectsUnknownItem(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	orderID := "ORD-" + newUUID()
	_, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: "does-not-exist", Quantity: 1}))

	var unavailable *ErrItemUnavailable
	if !errors.As(err, &unavailable) {
		t.Fatalf("err = %v, want ErrItemUnavailable", err)
	}
}

func TestShopRepo_OrderHistory_ReturnsFrozenPriceAndShipping(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 40, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)

	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 2})); err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}

	// Move the catalog price after the purchase: the receipt must not follow it.
	if _, err := testDB.Exec(ctx, "UPDATE shop_item SET price = 999 WHERE id = $1", item); err != nil {
		t.Fatalf("failed to change price: %v", err)
	}

	orders, err := repo.OrderHistory(ctx, fixture.userID, fixture.eventID)
	if err != nil {
		t.Fatalf("OrderHistory returned error: %v", err)
	}
	if len(orders) != 1 {
		t.Fatalf("got %d orders, want 1", len(orders))
	}
	o := orders[0]
	if o.OrderID != orderID {
		t.Errorf("orderId = %q, want %q", o.OrderID, orderID)
	}
	if o.EventID != fixture.eventID {
		t.Errorf("eventId = %q, want %q", o.EventID, fixture.eventID)
	}
	if models.ScaleCoins(o.Total) != models.ScaleCoins(80) {
		t.Errorf("total = %v, want 80", o.Total)
	}
	if o.ShippingCity != "Colombo" || o.ShippingCountry != "LK" {
		t.Errorf("shipping = %+v, want the submitted address", o)
	}
	// An omitted optional line must come back empty, not as the string "<nil>".
	if o.ShippingAddressLine2 != "" {
		t.Errorf("shippingAddressLine2 = %q, want empty", o.ShippingAddressLine2)
	}
	if len(o.Items) != 1 {
		t.Fatalf("got %d lines, want 1", len(o.Items))
	}
	line := o.Items[0]
	if models.ScaleCoins(line.PriceAtPurchase) != models.ScaleCoins(40) {
		t.Errorf("priceAtPurchase = %v, want the 40 paid, not the new catalog price", line.PriceAtPurchase)
	}
	// Both spellings the client may read must agree.
	if line.ItemID != line.ID || line.Price != line.PriceAtPurchase {
		t.Errorf("line's duplicated fields disagree: %+v", line)
	}
}

// The legacy query inner-joined shop_item, so a line whose item was later removed
// vanished and the receipt stopped adding up to its own total.
func TestShopRepo_OrderHistory_KeepsLineWhenItemSoftDeleted(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 15, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)

	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 1})); err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}
	if _, err := testDB.Exec(ctx, "UPDATE shop_item SET visibility = 'DELETED' WHERE id = $1", item); err != nil {
		t.Fatalf("failed to soft-delete item: %v", err)
	}

	orders, err := repo.OrderHistory(ctx, fixture.userID, fixture.eventID)
	if err != nil {
		t.Fatalf("OrderHistory returned error: %v", err)
	}
	if len(orders) != 1 || len(orders[0].Items) != 1 {
		t.Fatalf("the soft-deleted item's line was dropped: %+v", orders)
	}
	if models.ScaleCoins(orders[0].Items[0].PriceAtPurchase) != models.ScaleCoins(15) {
		t.Errorf("priceAtPurchase = %v, want 15", orders[0].Items[0].PriceAtPurchase)
	}
}

func TestShopRepo_OrderHistory_ScopesToTheUser(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 10, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)
	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 1})); err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}

	orders, err := repo.OrderHistory(ctx, newUUID(), fixture.eventID)
	if err != nil {
		t.Fatalf("OrderHistory returned error: %v", err)
	}
	for _, o := range orders {
		if o.OrderID == orderID {
			t.Fatal("another user's order was returned")
		}
	}
}

func TestShopRepo_ConfirmOrder_MarksConfirmedAndStoresHash(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 25, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)
	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 2})); err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}

	txHash := "0x" + newUUID()
	var verifiedTotal float64
	err := repo.ConfirmOrder(ctx, orderID, fixture.userID, txHash, "shopper@example.com",
		func(ctx context.Context, expectedTotal float64) error {
			verifiedTotal = expectedTotal
			return nil
		})
	if err != nil {
		t.Fatalf("ConfirmOrder returned error: %v", err)
	}

	// Verification must be handed the order's own stored total, not anything a
	// caller supplied.
	if models.ScaleCoins(verifiedTotal) != models.ScaleCoins(50) {
		t.Errorf("verify saw total %v, want the stored 50", verifiedTotal)
	}

	var status string
	var storedHash *string
	if err := testDB.QueryRow(ctx, "SELECT status, transaction_hash FROM shop_order WHERE id = $1", orderID).
		Scan(&status, &storedHash); err != nil {
		t.Fatalf("failed to read back order: %v", err)
	}
	if status != models.ShopOrderStatusConfirmed {
		t.Errorf("status = %q, want CONFIRMED", status)
	}
	if storedHash == nil || *storedHash != txHash {
		t.Errorf("transaction_hash = %v, want %q", storedHash, txHash)
	}
}

// A rejected payment must leave the order PENDING and record no hash, so the user
// can retry.
func TestShopRepo_ConfirmOrder_FailedVerificationRollsBack(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 25, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)
	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 1})); err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}

	wantErr := errors.New("bad payment")
	err := repo.ConfirmOrder(ctx, orderID, fixture.userID, "0x"+newUUID(), "shopper@example.com",
		func(ctx context.Context, expectedTotal float64) error { return wantErr })
	if !errors.Is(err, wantErr) {
		t.Fatalf("err = %v, want the verification error", err)
	}

	var status string
	var storedHash *string
	if err := testDB.QueryRow(ctx, "SELECT status, transaction_hash FROM shop_order WHERE id = $1", orderID).
		Scan(&status, &storedHash); err != nil {
		t.Fatalf("failed to read back order: %v", err)
	}
	if status != models.ShopOrderStatusPending {
		t.Errorf("status = %q, want PENDING after a rejected payment", status)
	}
	if storedHash != nil {
		t.Errorf("transaction_hash = %v, want NULL after a rejected payment", *storedHash)
	}
}

func TestShopRepo_ConfirmOrder_RejectsAnotherUsersOrder(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 25, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)
	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 1})); err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}

	verifyCalled := false
	err := repo.ConfirmOrder(ctx, orderID, newUUID(), "0x"+newUUID(), "attacker@example.com",
		func(ctx context.Context, expectedTotal float64) error {
			verifyCalled = true
			return nil
		})
	if !errors.Is(err, ErrOrderNotOwned) {
		t.Fatalf("err = %v, want ErrOrderNotOwned", err)
	}
	if verifyCalled {
		t.Error("verification ran for a caller who does not own the order")
	}
}

// The second confirm of an order must be a clean, specific error -- the legacy
// service returned a 500 here.
func TestShopRepo_ConfirmOrder_SecondConfirmIsNotPending(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 25, 10, "", nil)
	orderID := "ORD-" + newUUID()
	fixture.cleanupOrder(t, orderID)
	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(orderID, models.CheckoutItem{ID: item, Quantity: 1})); err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}

	ok := func(ctx context.Context, expectedTotal float64) error { return nil }
	if err := repo.ConfirmOrder(ctx, orderID, fixture.userID, "0x"+newUUID(), "s@example.com", ok); err != nil {
		t.Fatalf("first ConfirmOrder returned error: %v", err)
	}

	err := repo.ConfirmOrder(ctx, orderID, fixture.userID, "0x"+newUUID(), "s@example.com", ok)
	if !errors.Is(err, ErrOrderNotPending) {
		t.Fatalf("err = %v, want ErrOrderNotPending", err)
	}
}

// One on-chain payment must not be able to settle two orders.
func TestShopRepo_ConfirmOrder_RejectsHashAlreadyUsedByAnotherOrder(t *testing.T) {
	ctx := context.Background()
	fixture := newShopFixture(t, ctx, nil)
	repo := NewShopRepo(testDB)

	item := fixture.insertItem(t, ctx, 10, 20, "", nil)
	first := "ORD-" + newUUID()
	second := "ORD-" + newUUID()
	fixture.cleanupOrder(t, first)
	fixture.cleanupOrder(t, second)

	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(first, models.CheckoutItem{ID: item, Quantity: 1})); err != nil {
		t.Fatalf("first Checkout returned error: %v", err)
	}
	if _, _, err := repo.Checkout(ctx, fixture.checkoutParams(second, models.CheckoutItem{ID: item, Quantity: 1})); err != nil {
		t.Fatalf("second Checkout returned error: %v", err)
	}

	txHash := "0x" + newUUID()
	ok := func(ctx context.Context, expectedTotal float64) error { return nil }
	if err := repo.ConfirmOrder(ctx, first, fixture.userID, txHash, "s@example.com", ok); err != nil {
		t.Fatalf("first ConfirmOrder returned error: %v", err)
	}

	err := repo.ConfirmOrder(ctx, second, fixture.userID, txHash, "s@example.com", ok)
	if !errors.Is(err, ErrTxHashAlreadyUsed) {
		t.Fatalf("err = %v, want ErrTxHashAlreadyUsed", err)
	}

	var status string
	if err := testDB.QueryRow(ctx, "SELECT status FROM shop_order WHERE id = $1", second).Scan(&status); err != nil {
		t.Fatalf("failed to read back order: %v", err)
	}
	if status != models.ShopOrderStatusPending {
		t.Errorf("status = %q, want the second order left PENDING", status)
	}
}

func TestShopRepo_ConfirmOrder_UnknownOrderIsNotFound(t *testing.T) {
	ctx := context.Background()
	repo := NewShopRepo(testDB)

	err := repo.ConfirmOrder(ctx, "ORD-nope-"+newUUID(), newUUID(), "0xabc", "s@example.com",
		func(ctx context.Context, expectedTotal float64) error { return nil })
	if !errors.Is(err, ErrNotFound) {
		t.Fatalf("err = %v, want ErrNotFound", err)
	}
}
