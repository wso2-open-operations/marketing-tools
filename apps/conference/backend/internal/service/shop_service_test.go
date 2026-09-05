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

package service

import (
	"context"
	"errors"
	"strings"
	"testing"

	"wso2-coin-backend/internal/clients/transaction"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

const testMasterWallet = "0xMASTERwallet"

type fakeShopRepo struct {
	eventID    string
	isOpen     bool
	eventErr   error
	items      []models.ShopItem
	itemsErr   error
	orders     []models.ShopOrder
	ordersErr  error
	orderID    string
	total      float64
	checkotErr error
	confirmErr error

	// storedTotal is what ConfirmOrder hands to the verify callback, standing in
	// for the order's persisted total.
	storedTotal float64

	lastCheckout   repository.CheckoutParams
	lastItemsEvent string
	verifyErr      error
	verifyCalled   bool
}

func (f *fakeShopRepo) CurrentShopEvent(ctx context.Context) (string, bool, error) {
	return f.eventID, f.isOpen, f.eventErr
}

func (f *fakeShopRepo) ListItems(ctx context.Context, eventID string) ([]models.ShopItem, error) {
	f.lastItemsEvent = eventID
	return f.items, f.itemsErr
}

func (f *fakeShopRepo) OrderHistory(ctx context.Context, userUUID, eventID string) ([]models.ShopOrder, error) {
	return f.orders, f.ordersErr
}

func (f *fakeShopRepo) Checkout(ctx context.Context, p repository.CheckoutParams) (string, float64, error) {
	f.lastCheckout = p
	return f.orderID, f.total, f.checkotErr
}

func (f *fakeShopRepo) ConfirmOrder(
	ctx context.Context,
	orderID, userUUID, txHash, updatedBy string,
	verify func(ctx context.Context, expectedTotal float64) error,
) error {
	if f.confirmErr != nil {
		return f.confirmErr
	}
	f.verifyCalled = true
	f.verifyErr = verify(ctx, f.storedTotal)
	return f.verifyErr
}

func (f *fakeShopRepo) MarkStaleOrders(ctx context.Context, timeoutMinutes int) (int, error) {
	return 0, nil
}

type fakeTxClient struct {
	details transaction.TransactionDetails
	err     error
	lastTx  string
}

func (f *fakeTxClient) GetTransactionDetails(ctx context.Context, txHash string) (transaction.TransactionDetails, error) {
	f.lastTx = txHash
	return f.details, f.err
}

type fakeEmailClient struct {
	err error
}

func (f *fakeEmailClient) SendEmail(ctx context.Context, to []string, subject, template string) error {
	return f.err
}

func newTestShopService(repo *fakeShopRepo, tx *fakeTxClient) *ShopService {
	s := NewShopService(repo, tx, &fakeEmailClient{}, ShopConfig{MasterWalletAddress: testMasterWallet})
	s.NewOrderID = func() string { return "ORD-fixed" }
	return s
}

// validDetails is a transaction that passes every verification condition for a
// 100-coin order. Each test below breaks exactly one field.
func validDetails() transaction.TransactionDetails {
	amount := "100.0000"
	return transaction.TransactionDetails{
		Found:           true,
		Success:         true,
		Status:          "SUCCESS",
		AmountFormatted: &amount,
		DecodedData: &struct {
			Name string   `json:"name"`
			Args []string `json:"args"`
		}{Name: "transfer", Args: []string{testMasterWallet}},
	}
}

func TestShopService_Catalog_ReportsEventAndOpenState(t *testing.T) {
	repo := &fakeShopRepo{
		eventID: "event-1",
		isOpen:  true,
		items:   []models.ShopItem{{ID: "item-1"}},
	}
	got, err := newTestShopService(repo, &fakeTxClient{}).Catalog(context.Background())
	if err != nil {
		t.Fatalf("Catalog returned error: %v", err)
	}
	if got.ActiveEventID != "event-1" || !got.IsShopOpen || len(got.Items) != 1 {
		t.Errorf("got %+v, want event-1 / open / 1 item", got)
	}
	if repo.lastItemsEvent != "event-1" {
		t.Errorf("items listed for %q, want event-1", repo.lastItemsEvent)
	}
}

// A closed shop still returns its catalog: the client renders a closed state and
// still needs items to resolve past orders' lines.
func TestShopService_Catalog_ClosedShopStillReturnsItems(t *testing.T) {
	repo := &fakeShopRepo{eventID: "event-1", isOpen: false, items: []models.ShopItem{{ID: "item-1"}}}
	got, err := newTestShopService(repo, &fakeTxClient{}).Catalog(context.Background())
	if err != nil {
		t.Fatalf("Catalog returned error: %v", err)
	}
	if got.IsShopOpen {
		t.Error("isShopOpen = true, want false")
	}
	if len(got.Items) != 1 {
		t.Errorf("items = %d, want 1 even though the shop is closed", len(got.Items))
	}
}

// With no conference configured at all, an empty closed catalog is a truthful
// answer that keeps the client rendering rather than showing an error page.
func TestShopService_Catalog_NoConferenceIsEmptyAndClosed(t *testing.T) {
	repo := &fakeShopRepo{eventErr: repository.ErrNotFound}
	got, err := newTestShopService(repo, &fakeTxClient{}).Catalog(context.Background())
	if err != nil {
		t.Fatalf("Catalog returned error: %v", err)
	}
	if got.IsShopOpen {
		t.Error("isShopOpen = true, want false")
	}
	if got.Items == nil {
		t.Error("Items is nil; must serialize as [] not null")
	}
}

func TestShopService_OrderHistory_NilBecomesEmptySlice(t *testing.T) {
	repo := &fakeShopRepo{orders: nil}
	got, err := newTestShopService(repo, &fakeTxClient{}).OrderHistory(context.Background(), "user-1")
	if err != nil {
		t.Fatalf("OrderHistory returned error: %v", err)
	}
	if got == nil {
		t.Error("got nil; must be an empty slice so the response is [] not null")
	}
}

// The client sends an eventId from its own build-time config. Honouring it would
// let a stale client write orders against the wrong conference, so the server's
// resolved event must win.
func TestShopService_Checkout_IgnoresClientSuppliedEventID(t *testing.T) {
	repo := &fakeShopRepo{eventID: "server-event", isOpen: true, orderID: "ORD-fixed"}
	svc := newTestShopService(repo, &fakeTxClient{})

	_, err := svc.Checkout(context.Background(), "user-1", "u@example.com", models.CheckoutRequest{
		EventID: "client-event",
		Items:   []models.CheckoutItem{{ID: "item-1", Quantity: 1}},
	})
	if err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}
	if repo.lastCheckout.EventID != "server-event" {
		t.Errorf("order written against %q, want the server-resolved server-event", repo.lastCheckout.EventID)
	}
}

func TestShopService_Checkout_ClosedShopIsRefused(t *testing.T) {
	repo := &fakeShopRepo{eventID: "event-1", isOpen: false}
	svc := newTestShopService(repo, &fakeTxClient{})

	_, err := svc.Checkout(context.Background(), "user-1", "u@example.com", models.CheckoutRequest{
		Items: []models.CheckoutItem{{ID: "item-1", Quantity: 1}},
	})
	if !errors.Is(err, repository.ErrShopClosed) {
		t.Fatalf("err = %v, want ErrShopClosed", err)
	}
	if repo.lastCheckout.OrderID != "" {
		t.Error("an order was created against a closed shop")
	}
}

func TestShopService_Checkout_NoConferenceIsShopClosed(t *testing.T) {
	repo := &fakeShopRepo{eventErr: repository.ErrNotFound}
	svc := newTestShopService(repo, &fakeTxClient{})

	_, err := svc.Checkout(context.Background(), "user-1", "u@example.com", models.CheckoutRequest{
		Items: []models.CheckoutItem{{ID: "item-1", Quantity: 1}},
	})
	if !errors.Is(err, repository.ErrShopClosed) {
		t.Fatalf("err = %v, want ErrShopClosed", err)
	}
}

// Stock and limit errors must reach the handler unwrapped, or it cannot build the
// {itemId, availableQuantity} body the client repairs its cart from.
func TestShopService_Checkout_PassesClientFixableErrorsThrough(t *testing.T) {
	cases := []struct {
		name string
		err  error
	}{
		{"stock shortfall", &repository.ErrStockShortfall{ItemID: "i1", Available: 2}},
		{"unavailable item", &repository.ErrItemUnavailable{ItemID: "i1"}},
		{"per-user limit", &repository.ErrPerUserLimit{ItemID: "i1", Limit: 2, Purchased: 2}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			repo := &fakeShopRepo{eventID: "e1", isOpen: true, checkotErr: tc.err}
			svc := newTestShopService(repo, &fakeTxClient{})

			_, err := svc.Checkout(context.Background(), "user-1", "u@example.com", models.CheckoutRequest{
				Items: []models.CheckoutItem{{ID: "i1", Quantity: 1}},
			})
			if !errors.Is(err, tc.err) {
				t.Fatalf("err = %v, want the original %v unwrapped", err, tc.err)
			}
		})
	}
}

func TestShopService_Checkout_ReturnsNullTransactionHash(t *testing.T) {
	repo := &fakeShopRepo{eventID: "e1", isOpen: true, orderID: "ORD-fixed"}
	svc := newTestShopService(repo, &fakeTxClient{})

	got, err := svc.Checkout(context.Background(), "user-1", "u@example.com", models.CheckoutRequest{
		Items: []models.CheckoutItem{{ID: "i1", Quantity: 1}},
	})
	if err != nil {
		t.Fatalf("Checkout returned error: %v", err)
	}
	if got.OrderID != "ORD-fixed" {
		t.Errorf("orderId = %q, want ORD-fixed", got.OrderID)
	}
	if got.TransactionHash != nil {
		t.Errorf("transactionHash = %v, want nil until confirm records one", *got.TransactionHash)
	}
}

// A deployment with no master wallet must refuse to confirm rather than skip the
// recipient check -- otherwise it hands out merchandise for free.
func TestShopService_Confirm_RefusesWithoutMasterWallet(t *testing.T) {
	repo := &fakeShopRepo{storedTotal: 100}
	svc := NewShopService(repo, &fakeTxClient{details: validDetails()}, &fakeEmailClient{}, ShopConfig{MasterWalletAddress: "  "})

	_, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com", models.CheckoutConfirmRequest{
		OrderID: "ORD-1", TransactionHash: "0xabc",
	})
	if !errors.Is(err, ErrMasterWalletNotConfigured) {
		t.Fatalf("err = %v, want ErrMasterWalletNotConfigured", err)
	}
	if repo.verifyCalled {
		t.Error("verification ran despite there being no wallet to verify against")
	}
}

func TestShopService_Confirm_SucceedsOnValidTransaction(t *testing.T) {
	repo := &fakeShopRepo{storedTotal: 100}
	tx := &fakeTxClient{details: validDetails()}
	svc := newTestShopService(repo, tx)

	got, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com", models.CheckoutConfirmRequest{
		OrderID: "ORD-1", TransactionHash: "0xabc",
	})
	if err != nil {
		t.Fatalf("ConfirmCheckout returned error: %v", err)
	}
	if got.OrderID != "ORD-1" {
		t.Errorf("orderId = %q, want ORD-1", got.OrderID)
	}
	if got.TransactionHash == nil || *got.TransactionHash != "0xabc" {
		t.Errorf("transactionHash = %v, want 0xabc", got.TransactionHash)
	}
	if tx.lastTx != "0xabc" {
		t.Errorf("looked up %q on-chain, want 0xabc", tx.lastTx)
	}
}

// Each case breaks exactly one condition of an otherwise-valid transaction, so a
// regression that drops a check fails exactly one test.
func TestShopService_VerifyPayment_RejectsEachInvalidCondition(t *testing.T) {
	otherAmount := "99.0000"
	zero := "0"
	notANumber := "not-a-number"

	cases := []struct {
		name   string
		mutate func(*transaction.TransactionDetails)
	}{
		{"not on chain", func(d *transaction.TransactionDetails) { d.Found = false }},
		{"missing decoded data", func(d *transaction.TransactionDetails) { d.DecodedData = nil }},
		{"not a transfer call", func(d *transaction.TransactionDetails) { d.DecodedData.Name = "approve" }},
		{"no transfer arguments", func(d *transaction.TransactionDetails) { d.DecodedData.Args = nil }},
		{"wrong recipient", func(d *transaction.TransactionDetails) {
			d.DecodedData.Args = []string{"0xSOMEONEelse"}
		}},
		{"missing amount", func(d *transaction.TransactionDetails) { d.AmountFormatted = nil }},
		{"unparseable amount", func(d *transaction.TransactionDetails) { d.AmountFormatted = &notANumber }},
		{"underpaid", func(d *transaction.TransactionDetails) { d.AmountFormatted = &otherAmount }},
		{"zero amount", func(d *transaction.TransactionDetails) { d.AmountFormatted = &zero }},
		{"not successful", func(d *transaction.TransactionDetails) { d.Success = false }},
		{"status not SUCCESS", func(d *transaction.TransactionDetails) { d.Status = "PENDING" }},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			details := validDetails()
			tc.mutate(&details)

			repo := &fakeShopRepo{storedTotal: 100}
			svc := newTestShopService(repo, &fakeTxClient{details: details})

			_, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com",
				models.CheckoutConfirmRequest{OrderID: "ORD-1", TransactionHash: "0xabc"})

			if !errors.Is(err, ErrPaymentVerificationFailed) {
				t.Fatalf("err = %v, want ErrPaymentVerificationFailed", err)
			}
		})
	}
}

// Address casing is a checksum encoding, not an identity: a correctly-cased
// payment to the right wallet must not be rejected.
func TestShopService_VerifyPayment_RecipientCompareIsCaseInsensitive(t *testing.T) {
	details := validDetails()
	details.DecodedData.Args = []string{strings.ToUpper(testMasterWallet)}

	repo := &fakeShopRepo{storedTotal: 100}
	svc := newTestShopService(repo, &fakeTxClient{details: details})

	if _, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com",
		models.CheckoutConfirmRequest{OrderID: "ORD-1", TransactionHash: "0xabc"}); err != nil {
		t.Fatalf("ConfirmCheckout returned error: %v", err)
	}
}

// A payment must verify against the order's *stored* total, never anything the
// caller supplied -- that is the whole point of doing it server-side.
func TestShopService_VerifyPayment_ComparesAgainstStoredTotal(t *testing.T) {
	amount := "100.0000"
	details := validDetails()
	details.AmountFormatted = &amount

	// The stored order is for 250, so a 100-coin payment must fail even though
	// the transaction itself is perfectly valid.
	repo := &fakeShopRepo{storedTotal: 250}
	svc := newTestShopService(repo, &fakeTxClient{details: details})

	_, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com",
		models.CheckoutConfirmRequest{OrderID: "ORD-1", TransactionHash: "0xabc"})
	if !errors.Is(err, ErrPaymentVerificationFailed) {
		t.Fatalf("err = %v, want the payment rejected against the stored total", err)
	}
}

// Amounts are compared at the schema's 4-decimal precision, so a float
// representation artifact cannot reject a correct payment.
func TestShopService_VerifyPayment_ToleratesFloatRepresentation(t *testing.T) {
	amount := "0.3000"
	details := validDetails()
	details.AmountFormatted = &amount

	// 0.1 + 0.2 is 0.30000000000000004 in float64.
	repo := &fakeShopRepo{storedTotal: 0.1 + 0.2}
	svc := newTestShopService(repo, &fakeTxClient{details: details})

	if _, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com",
		models.CheckoutConfirmRequest{OrderID: "ORD-1", TransactionHash: "0xabc"}); err != nil {
		t.Fatalf("a correct payment was rejected by float comparison: %v", err)
	}
}

// An unreachable blockchain service is an internal fault, not a verification
// failure: telling the user their payment was invalid would be wrong.
func TestShopService_Confirm_UpstreamErrorIsNotAVerificationFailure(t *testing.T) {
	repo := &fakeShopRepo{storedTotal: 100}
	svc := newTestShopService(repo, &fakeTxClient{err: errors.New("chain unreachable")})

	_, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com",
		models.CheckoutConfirmRequest{OrderID: "ORD-1", TransactionHash: "0xabc"})
	if err == nil {
		t.Fatal("expected an error")
	}
	if errors.Is(err, ErrPaymentVerificationFailed) {
		t.Errorf("err = %v, want an internal error rather than a verification failure", err)
	}
}

func TestShopService_Confirm_RepoErrorsPassThrough(t *testing.T) {
	cases := []error{
		repository.ErrNotFound,
		repository.ErrOrderNotOwned,
		repository.ErrOrderNotPending,
		repository.ErrTxHashAlreadyUsed,
	}
	for _, want := range cases {
		t.Run(want.Error(), func(t *testing.T) {
			repo := &fakeShopRepo{confirmErr: want}
			svc := newTestShopService(repo, &fakeTxClient{details: validDetails()})

			_, err := svc.ConfirmCheckout(context.Background(), "user-1", "u@example.com",
				models.CheckoutConfirmRequest{OrderID: "ORD-1", TransactionHash: "0xabc"})
			if !errors.Is(err, want) {
				t.Fatalf("err = %v, want %v", err, want)
			}
		})
	}
}

// Order ids are printed on receipts and quoted to support, so the format is part
// of the contract.
func TestNewOrderID_HasLegacyPrefixAndIsUnique(t *testing.T) {
	first := newOrderID()
	second := newOrderID()

	if !strings.HasPrefix(first, "ORD-") {
		t.Errorf("order id %q does not start with ORD-", first)
	}
	// "ORD-" plus a 36-character UUID.
	if len(first) != 40 {
		t.Errorf("order id %q has length %d, want 40", first, len(first))
	}
	if first == second {
		t.Error("two consecutive order ids are identical")
	}
}
