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
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
	"wso2-coin-backend/internal/service"
)

type fakeShopService struct {
	catalog     models.ShopCatalog
	catalogErr  error
	orders      []models.ShopOrder
	ordersErr   error
	checkout    models.CheckoutResponse
	checkoutErr error
	confirm     models.CheckoutResponse
	confirmErr  error

	lastCheckoutUser   string
	lastCheckoutReq    models.CheckoutRequest
	lastConfirmUser    string
	lastConfirmReq     models.CheckoutConfirmRequest
	lastOrdersUserUUID string
}

func (f *fakeShopService) Catalog(ctx context.Context) (models.ShopCatalog, error) {
	return f.catalog, f.catalogErr
}

func (f *fakeShopService) OrderHistory(ctx context.Context, userUUID string) ([]models.ShopOrder, error) {
	f.lastOrdersUserUUID = userUUID
	return f.orders, f.ordersErr
}

func (f *fakeShopService) Checkout(ctx context.Context, userUUID, email string, req models.CheckoutRequest) (models.CheckoutResponse, error) {
	f.lastCheckoutUser = userUUID
	f.lastCheckoutReq = req
	return f.checkout, f.checkoutErr
}

func (f *fakeShopService) ConfirmCheckout(ctx context.Context, userUUID, email string, req models.CheckoutConfirmRequest) (models.CheckoutResponse, error) {
	f.lastConfirmUser = userUUID
	f.lastConfirmReq = req
	return f.confirm, f.confirmErr
}

func newShopTestRouter(h *ShopHandler, user *middleware.UserInfo) *gin.Engine {
	r := gin.New()
	r.Use(func(c *gin.Context) {
		if user != nil {
			c.Request = c.Request.WithContext(middleware.WithUserInfo(c.Request.Context(), user))
		}
		c.Next()
	})
	r.GET("/shops/items", h.Items)
	r.GET("/shops/orders/me", h.Orders)
	r.POST("/shops/checkout", h.Checkout)
	r.POST("/shops/checkout/confirm", h.ConfirmCheckout)
	return r
}

func validCheckoutBody() map[string]any {
	return map[string]any{
		"idempotencyKey":        "key-1",
		"eventId":               "event-from-client",
		"totalCost":             1,
		"items":                 []map[string]any{{"id": "item-1", "quantity": 2}},
		"shippingRecipientName": "Jane Doe",
		"shippingEmail":         "jane@example.com",
		"shippingAddressLine1":  "1 Main St",
		"shippingCity":          "Colombo",
		"shippingCountry":       "LK",
	}
}

// The client reads shopData.items / .isShopOpen / .activeEventId, so the catalog
// must be an envelope and never a bare array.
func TestShopHandler_Items_ReturnsEnvelope(t *testing.T) {
	svc := &fakeShopService{catalog: models.ShopCatalog{
		Items:         []models.ShopItem{{ID: "item-1", Name: "Cap", Price: 10, Visibility: models.ShopVisibilityVisible}},
		IsShopOpen:    true,
		ActiveEventID: "event-1",
	}}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodGet, "/shops/items", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var got struct {
		Items         []models.ShopItem `json:"items"`
		IsShopOpen    bool              `json:"isShopOpen"`
		ActiveEventID string            `json:"activeEventId"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("response is not the catalog envelope: %v (%s)", err, rec.Body.String())
	}
	if len(got.Items) != 1 || got.Items[0].ID != "item-1" {
		t.Errorf("items = %+v, want one item-1", got.Items)
	}
	if !got.IsShopOpen {
		t.Error("isShopOpen = false, want true")
	}
	if got.ActiveEventID != "event-1" {
		t.Errorf("activeEventId = %q, want event-1", got.ActiveEventID)
	}
}

func TestShopHandler_Items_ServiceErrorIs500(t *testing.T) {
	svc := &fakeShopService{catalogErr: errors.New("boom")}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodGet, "/shops/items", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestShopHandler_Orders_ScopesToCaller(t *testing.T) {
	svc := &fakeShopService{orders: []models.ShopOrder{{OrderID: "ORD-1", Status: models.ShopOrderStatusPending}}}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodGet, "/shops/orders/me", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	if svc.lastOrdersUserUUID != testUser.UserID {
		t.Errorf("order history requested for %q, want the caller %q", svc.lastOrdersUserUUID, testUser.UserID)
	}
}

// A caller with no orders must get [], not null: the client destructures the
// result as an array and iterates it without a guard.
func TestShopHandler_Orders_EmptyIsEmptyArray(t *testing.T) {
	svc := &fakeShopService{orders: nil}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodGet, "/shops/orders/me", nil)

	if got := rec.Body.String(); got != "[]" {
		t.Errorf("body = %s, want []", got)
	}
}

func TestShopHandler_Orders_MissingUserIs401(t *testing.T) {
	rec := doRequest(newShopTestRouter(NewShopHandler(&fakeShopService{}), nil), http.MethodGet, "/shops/orders/me", nil)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestShopHandler_Checkout_ReturnsOrderID(t *testing.T) {
	svc := &fakeShopService{checkout: models.CheckoutResponse{OrderID: "ORD-abc"}}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout", validCheckoutBody())

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}

	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["orderId"] != "ORD-abc" {
		t.Errorf("orderId = %v, want ORD-abc", got["orderId"])
	}
	// transactionHash must be present and null, so the client's `res.orderId ||
	// res.data?.orderId` chain never sees a partially-shaped body.
	if v, ok := got["transactionHash"]; !ok || v != nil {
		t.Errorf("transactionHash = %v (present=%t), want an explicit null", v, ok)
	}
	if svc.lastCheckoutUser != testUser.UserID {
		t.Errorf("checkout ran as %q, want %q", svc.lastCheckoutUser, testUser.UserID)
	}
}

func TestShopHandler_Checkout_MissingUserIs401(t *testing.T) {
	rec := doRequest(newShopTestRouter(NewShopHandler(&fakeShopService{}), nil), http.MethodPost, "/shops/checkout", validCheckoutBody())

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}

func TestShopHandler_Checkout_ValidationFailureIs400(t *testing.T) {
	body := validCheckoutBody()
	body["items"] = []map[string]any{}

	rec := doRequest(newShopTestRouter(NewShopHandler(&fakeShopService{}), testUser), http.MethodPost, "/shops/checkout", body)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// This is the contract the client repairs its cart from: it looks up itemId and
// clamps the line to availableQuantity. Both fields have to be on the 400 body.
func TestShopHandler_Checkout_StockShortfallCarriesItemAndAvailable(t *testing.T) {
	svc := &fakeShopService{checkoutErr: &repository.ErrStockShortfall{ItemID: "item-1", Available: 3}}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout", validCheckoutBody())

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}

	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["itemId"] != "item-1" {
		t.Errorf("itemId = %v, want item-1", got["itemId"])
	}
	if got["availableQuantity"] != float64(3) {
		t.Errorf("availableQuantity = %v, want 3", got["availableQuantity"])
	}
}

// A per-user cap reports the caller's *remaining* allowance, not the cap, since
// the client treats the number as "how many you may still have".
func TestShopHandler_Checkout_PerUserLimitReportsRemaining(t *testing.T) {
	svc := &fakeShopService{checkoutErr: &repository.ErrPerUserLimit{ItemID: "item-1", Limit: 5, Purchased: 4}}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout", validCheckoutBody())

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}

	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["availableQuantity"] != float64(1) {
		t.Errorf("availableQuantity = %v, want 1 (5 limit - 4 purchased)", got["availableQuantity"])
	}
}

// An over-cap purchase must not report a negative allowance -- the client would
// compute a nonsensical quantity from it.
func TestShopHandler_Checkout_PerUserLimitNeverReportsNegative(t *testing.T) {
	svc := &fakeShopService{checkoutErr: &repository.ErrPerUserLimit{ItemID: "item-1", Limit: 2, Purchased: 5}}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout", validCheckoutBody())

	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["availableQuantity"] != float64(0) {
		t.Errorf("availableQuantity = %v, want 0", got["availableQuantity"])
	}
}

// An unavailable item must NOT carry availableQuantity: the client reads a 0 as
// "sold out" and silently drops the line, which would hide a real misconfiguration.
func TestShopHandler_Checkout_UnavailableItemOmitsAvailableQuantity(t *testing.T) {
	svc := &fakeShopService{checkoutErr: &repository.ErrItemUnavailable{ItemID: "item-9"}}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout", validCheckoutBody())

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}

	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["itemId"] != "item-9" {
		t.Errorf("itemId = %v, want item-9", got["itemId"])
	}
	if _, present := got["availableQuantity"]; present {
		t.Error("availableQuantity is present; an unavailable item must not look like a sold-out one")
	}
}

func TestShopHandler_Checkout_ShopClosedIs409(t *testing.T) {
	svc := &fakeShopService{checkoutErr: repository.ErrShopClosed}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout", validCheckoutBody())

	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestShopHandler_Checkout_UnexpectedErrorIs500(t *testing.T) {
	svc := &fakeShopService{checkoutErr: errors.New("boom")}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout", validCheckoutBody())

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("expected 500, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestShopHandler_Confirm_ReturnsOrderAndHash(t *testing.T) {
	hash := "0xabc"
	svc := &fakeShopService{confirm: models.CheckoutResponse{OrderID: "ORD-1", TransactionHash: &hash}}
	body := map[string]any{"orderId": "ORD-1", "transactionHash": hash}

	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser), http.MethodPost, "/shops/checkout/confirm", body)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["orderId"] != "ORD-1" {
		t.Errorf("orderId = %v, want ORD-1", got["orderId"])
	}
	if got["transactionHash"] != hash {
		t.Errorf("transactionHash = %v, want %s", got["transactionHash"], hash)
	}
}

func TestShopHandler_Confirm_ValidationFailureIs400(t *testing.T) {
	rec := doRequest(newShopTestRouter(NewShopHandler(&fakeShopService{}), testUser),
		http.MethodPost, "/shops/checkout/confirm", map[string]any{"orderId": "ORD-1"})

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestShopHandler_Confirm_ErrorMapping(t *testing.T) {
	hash := "0xabc"
	body := map[string]any{"orderId": "ORD-1", "transactionHash": hash}

	cases := []struct {
		name     string
		err      error
		wantCode int
	}{
		{"unknown order is 400", repository.ErrNotFound, http.StatusBadRequest},
		// 403 not 404: the order exists, the caller just isn't entitled to it.
		{"another user's order is 403", repository.ErrOrderNotOwned, http.StatusForbidden},
		// 409 not 500: a replay or a lost race is not a server fault.
		{"already-settled order is 409", repository.ErrOrderNotPending, http.StatusConflict},
		{"reused transaction hash is 400", repository.ErrTxHashAlreadyUsed, http.StatusBadRequest},
		{"failed verification is 400", service.ErrPaymentVerificationFailed, http.StatusBadRequest},
		// 503 not 500: the deployment is missing config, the request is fine.
		{"unconfigured master wallet is 503", service.ErrMasterWalletNotConfigured, http.StatusServiceUnavailable},
		{"unexpected error is 500", errors.New("boom"), http.StatusInternalServerError},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			svc := &fakeShopService{confirmErr: tc.err}
			rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser),
				http.MethodPost, "/shops/checkout/confirm", body)

			if rec.Code != tc.wantCode {
				t.Fatalf("got %d, want %d: %s", rec.Code, tc.wantCode, rec.Body.String())
			}
		})
	}
}

// A missing SHOP_MASTER_WALLET_ADDRESS is a deployment fault, not the caller's,
// and it is not transient-per-request: 503 tells the client to stop retrying the
// same payment, and the message must not name the missing setting.
func TestShopHandler_Confirm_UnconfiguredWalletIs503AndLeaksNothing(t *testing.T) {
	svc := &fakeShopService{confirmErr: service.ErrMasterWalletNotConfigured}
	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser),
		http.MethodPost, "/shops/checkout/confirm",
		map[string]any{"orderId": "ORD-1", "transactionHash": "0xabc"})

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("got %d, want 503: %s", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	for _, leak := range []string{"wallet", "WALLET", "master", "config", "SHOP_"} {
		if strings.Contains(body, leak) {
			t.Errorf("response body leaks %q: %s", leak, body)
		}
	}
}

// The reason a verification failed must never reach the caller: it would let
// someone iterate toward a transaction that passes.
func TestShopHandler_Confirm_VerificationFailureLeaksNoReason(t *testing.T) {
	svc := &fakeShopService{
		confirmErr: errors.Join(service.ErrPaymentVerificationFailed,
			errors.New("transfer recipient is not the master wallet")),
	}
	body := map[string]any{"orderId": "ORD-1", "transactionHash": "0xabc"}

	rec := doRequest(newShopTestRouter(NewShopHandler(svc), testUser),
		http.MethodPost, "/shops/checkout/confirm", body)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
	var got map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &got)
	if got["message"] != "Transaction verification failed." {
		t.Errorf("message = %v, want the opaque verification message", got["message"])
	}
}

func TestShopHandler_Confirm_MissingUserIs401(t *testing.T) {
	body := map[string]any{"orderId": "ORD-1", "transactionHash": "0xabc"}
	rec := doRequest(newShopTestRouter(NewShopHandler(&fakeShopService{}), nil),
		http.MethodPost, "/shops/checkout/confirm", body)

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", rec.Code)
	}
}
