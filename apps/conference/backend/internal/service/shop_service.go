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
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"

	"wso2-coin-backend/internal/clients/transaction"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
	"log/slog"
)

// Shop-level sentinel errors raised by this service, mapped to HTTP status
// codes by the handler.
var (
	// ErrPaymentVerificationFailed means the on-chain payment did not satisfy
	// every verification condition. The specific reason is deliberately not part
	// of this error's client-facing message -- see verifyPayment.
	ErrPaymentVerificationFailed = errors.New("Transaction verification failed.")
	// ErrMasterWalletNotConfigured means the deployment has no master wallet
	// address, so no payment can be verified against anything.
	ErrMasterWalletNotConfigured = errors.New("shop payments are not configured")
)

// orderIDPrefix matches the legacy service's order id format ("ORD-" + uuid4).
// Order ids are printed on receipts and quoted to support, so the format is part
// of the contract, not an implementation detail.
const orderIDPrefix = "ORD-"

// verifyTimeout bounds the on-chain verification call.
//
// ConfirmOrder runs this inside an open database transaction, holding the
// order's FOR UPDATE lock and a pooled connection for its whole duration -- the
// lock has to span verify-then-update or two concurrent confirms could both
// settle. The pool is shared by the entire backend and is not large, so an
// unbounded call here couples the availability of every other endpoint to the
// transaction service's worst latency. This caps that exposure well under the
// client's own 15s transport timeout: a confirm that cannot be verified quickly
// is better failed and retried than left holding a connection.
const verifyTimeout = 5 * time.Second

// TransactionDetailsClient fetches a blockchain transaction for verification.
// Satisfied by *transaction.Client.
type TransactionDetailsClient interface {
	GetTransactionDetails(ctx context.Context, txHash string) (transaction.TransactionDetails, error)
}

type EmailClient interface {
	SendEmail(ctx context.Context, to []string, subject, template string) error
}

// ShopConfig holds the deployment settings the shop flow needs.
type ShopConfig struct {
	// MasterWalletAddress is the merchant wallet every shop payment must be
	// sent to. Verification compares the decoded transfer recipient against it,
	// which is what stops a caller confirming an order by pointing at any
	// unrelated transfer they can find on-chain.
	MasterWalletAddress string
	StaleOrderCleanupIntervalSeconds int
	CoinStaleOrderTimeoutMinutes     int
}

// ShopService orchestrates the shop catalog, order history and the two-step
// checkout. It sits here rather than in a handler because confirm needs a
// database transaction *and* an external call inside it, the same shape as
// CoinService.
type ShopService struct {
	shop        repository.ShopRepository
	transaction TransactionDetailsClient
	email       EmailClient
	cfg         ShopConfig

	// NewOrderID generates an order id; overridable in tests so a checkout
	// assertion doesn't depend on a random value.
	NewOrderID func() string
}

// NewShopService constructs a ShopService.
func NewShopService(shop repository.ShopRepository, txClient TransactionDetailsClient, emailClient EmailClient, cfg ShopConfig) *ShopService {
	return &ShopService{
		shop:        shop,
		transaction: txClient,
		email:       emailClient,
		cfg:         cfg,
		NewOrderID:  newOrderID,
	}
}

// newOrderID returns an order id of the form "ORD-" + a random UUIDv4.
//
// Hand-rolled rather than pulling in a UUID module: this is the only place in
// the service that mints an identifier (every table's own ids come from
// Postgres' gen_random_uuid()), and a dependency for 12 lines isn't worth it.
//
// crypto/rand.Read is documented never to return an error, so there is no
// fallback path to a weaker generator -- a predictable order id would let one
// attendee guess another's and probe it via confirm.
func newOrderID() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("shop: reading random bytes for order id: " + err.Error())
	}
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // RFC 4122 variant

	h := hex.EncodeToString(b[:])
	return orderIDPrefix + h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:32]
}

// Catalog returns the purchasable catalog for the current event, together with
// whether the shop is open and which event it belongs to.
//
// Items are returned even when the shop is closed. The client renders a
// closed-shop state and still needs the catalog to show what was on offer and to
// resolve the lines of past orders; it is checkout that must refuse, not this.
func (s *ShopService) Catalog(ctx context.Context) (models.ShopCatalog, error) {
	eventID, isOpen, err := s.shop.CurrentShopEvent(ctx)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			// No conference configured at all. An empty, closed catalog is a
			// truthful answer and keeps the client rendering rather than
			// erroring.
			return models.ShopCatalog{Items: []models.ShopItem{}, IsShopOpen: false}, nil
		}
		return models.ShopCatalog{}, fmt.Errorf("service: resolving current shop event: %w", err)
	}

	items, err := s.shop.ListItems(ctx, eventID)
	if err != nil {
		return models.ShopCatalog{}, fmt.Errorf("service: listing shop items: %w", err)
	}
	if items == nil {
		items = []models.ShopItem{}
	}

	return models.ShopCatalog{
		Items:         items,
		IsShopOpen:    isOpen,
		ActiveEventID: eventID,
	}, nil
}

// OrderHistory returns every order the caller has placed, newest first.
func (s *ShopService) OrderHistory(ctx context.Context, userUUID string) ([]models.ShopOrder, error) {
	eventID, _, err := s.shop.CurrentShopEvent(ctx)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return []models.ShopOrder{}, nil
		}
		return nil, fmt.Errorf("service: resolving current shop event: %w", err)
	}

	orders, err := s.shop.OrderHistory(ctx, userUUID, eventID)
	if err != nil {
		return nil, fmt.Errorf("service: listing shop orders: %w", err)
	}
	if orders == nil {
		orders = []models.ShopOrder{}
	}
	return orders, nil
}

// Checkout creates a PENDING order for the caller and reserves its stock.
//
// The event is resolved server-side from the current conference, not taken from
// the request's eventId: the client sends an id from its own build-time config,
// and honouring it would let a stale client write orders against the wrong
// conference. The field is accepted and ignored, exactly like totalCost.
//
// Returns ErrShopClosed once the event's shop_closing_time has passed. The
// client disables its own checkout button when the catalog reports the shop
// closed, but that is cosmetic -- this is the real gate.
func (s *ShopService) Checkout(ctx context.Context, userUUID, email string, req models.CheckoutRequest) (models.CheckoutResponse, error) {
	eventID, isOpen, err := s.shop.CurrentShopEvent(ctx)
	if err != nil {
		if errors.Is(err, repository.ErrNotFound) {
			return models.CheckoutResponse{}, repository.ErrShopClosed
		}
		return models.CheckoutResponse{}, fmt.Errorf("service: resolving current shop event: %w", err)
	}
	if !isOpen {
		return models.CheckoutResponse{}, repository.ErrShopClosed
	}

	orderID, _, err := s.shop.Checkout(ctx, repository.CheckoutParams{
		OrderID:  s.NewOrderID(),
		UserUUID: userUUID,
		Email:    email,
		EventID:  eventID,
		Request:  req,
	})
	if err != nil {
		// Stock/availability/limit errors are the caller's to fix and are
		// returned unwrapped so the handler can classify them; anything else is
		// an internal fault.
		var shortfall *repository.ErrStockShortfall
		var unavailable *repository.ErrItemUnavailable
		var limit *repository.ErrPerUserLimit
		if errors.As(err, &shortfall) || errors.As(err, &unavailable) || errors.As(err, &limit) {
			return models.CheckoutResponse{}, err
		}
		return models.CheckoutResponse{}, fmt.Errorf("service: creating shop order: %w", err)
	}

	// transactionHash is null until confirm records one.
	return models.CheckoutResponse{OrderID: orderID}, nil
}

// ConfirmCheckout verifies an order's on-chain payment and marks it CONFIRMED.
func (s *ShopService) ConfirmCheckout(ctx context.Context, userUUID, email string, req models.CheckoutConfirmRequest) (models.CheckoutResponse, error) {
	if strings.TrimSpace(s.cfg.MasterWalletAddress) == "" {
		// Refusing here rather than skipping verification is the whole point: a
		// deployment that forgot to configure the merchant wallet must not
		// confirm orders for free.
		return models.CheckoutResponse{}, ErrMasterWalletNotConfigured
	}

	verify := func(ctx context.Context, expectedTotal float64) error {
		// Bounded because this runs inside ConfirmOrder's transaction, holding a
		// pooled connection and the order's row lock -- see verifyTimeout.
		ctx, cancel := context.WithTimeout(ctx, verifyTimeout)
		defer cancel()

		details, err := s.transaction.GetTransactionDetails(ctx, req.TransactionHash)
		if err != nil {
			return fmt.Errorf("service: fetching transaction details: %w", err)
		}
		return s.verifyPayment(ctx, details, expectedTotal)
	}

	if err := s.shop.ConfirmOrder(ctx, req.OrderID, userUUID, req.TransactionHash, email, verify); err != nil {
		switch {
		case errors.Is(err, repository.ErrNotFound),
			errors.Is(err, repository.ErrOrderNotOwned),
			errors.Is(err, repository.ErrOrderNotPending),
			errors.Is(err, repository.ErrTxHashAlreadyUsed),
			errors.Is(err, ErrPaymentVerificationFailed):
			return models.CheckoutResponse{}, err
		default:
			return models.CheckoutResponse{}, fmt.Errorf("service: confirming shop order: %w", err)
		}
	}

	txHash := req.TransactionHash

	// Send confirmation email asynchronously
	go func(orderID, userEmail string) {
		bgCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		eventID, _, err := s.shop.CurrentShopEvent(bgCtx)
		if err != nil {
			slog.Error("failed to get current event for confirmation email", "order_id", orderID, "error", err)
			return
		}

		orders, err := s.shop.OrderHistory(bgCtx, userUUID, eventID)
		if err != nil {
			slog.Error("failed to get order for email", "order_id", orderID, "error", err)
			return
		}

		var confirmedOrder *models.ShopOrder
		for i := range orders {
			if orders[i].OrderID == orderID {
				confirmedOrder = &orders[i]
				break
			}
		}

		if confirmedOrder != nil {
			htmlBody := GenerateOrderConfirmationEmail(*confirmedOrder, confirmedOrder.ShippingRecipientName)
			err = s.email.SendEmail(bgCtx, []string{userEmail}, "Your WSO2 Conference Shop Order", htmlBody)
			if err != nil {
				slog.Error("failed to send order confirmation email", "order_id", orderID, "error", err)
			}
		}
	}(req.OrderID, email)

	return models.CheckoutResponse{OrderID: req.OrderID, TransactionHash: &txHash}, nil
}

// verifyPayment applies every condition a payment must satisfy before an order
// is confirmed. All of them must hold:
//
//   - the transaction exists on-chain
//   - it decodes as a "transfer" call with at least one argument
//   - its recipient is the configured master wallet (case-insensitive: address
//     casing is a checksum encoding, not an identity)
//   - its amount equals the order's stored total, at the 4 decimal places the
//     schema stores coin amounts to
//   - it both reports success and has status SUCCESS
//
// Every failure returns the same opaque ErrPaymentVerificationFailed to the
// caller while logging nothing here: telling a caller precisely which condition
// its forged transaction failed is a tool for finding one that passes. The
// specific reason is wrapped for the server-side log.
func (s *ShopService) verifyPayment(_ context.Context, d transaction.TransactionDetails, expectedTotal float64) error {
	fail := func(reason string) error {
		return fmt.Errorf("%w (%s)", ErrPaymentVerificationFailed, reason)
	}

	if !d.Found {
		return fail("transaction not found on-chain")
	}
	if d.DecodedData == nil {
		return fail("decoded transaction data missing")
	}
	if d.DecodedData.Name != "transfer" || len(d.DecodedData.Args) < 1 {
		return fail("transaction is not a transfer call")
	}
	if !strings.EqualFold(d.DecodedData.Args[0], s.cfg.MasterWalletAddress) {
		return fail("transfer recipient is not the master wallet")
	}
	if d.AmountFormatted == nil {
		return fail("transaction amount missing")
	}
	actual, err := strconv.ParseFloat(strings.TrimSpace(*d.AmountFormatted), 64)
	if err != nil {
		return fail("transaction amount is not a number")
	}
	// Compared at the schema's own precision rather than with ==, so a float
	// representation artifact cannot reject a correct payment.
	if models.ScaleCoins(actual) != models.ScaleCoins(expectedTotal) {
		return fail("transaction amount does not match the order total")
	}
	if !d.Success || d.Status != "SUCCESS" {
		return fail("transaction did not succeed")
	}

	return nil
}

// Start runs a background worker to periodically clean up stale PENDING orders.
func (s *ShopService) Start(ctx context.Context) {
	ticker := time.NewTicker(time.Duration(s.cfg.StaleOrderCleanupIntervalSeconds) * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			// Execute cleanup
			count, err := s.shop.MarkStaleOrders(ctx, s.cfg.CoinStaleOrderTimeoutMinutes)
			if err != nil {
				slog.Error("Failed to mark stale orders", "error", err)
			} else if count > 0 {
				slog.Info("Marked stale orders as EXPIRED", "count", count)
			}
		}
	}
}
