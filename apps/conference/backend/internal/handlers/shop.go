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
	"errors"
	"log/slog"
	"net/http"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/middleware"
	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
	"wso2-coin-backend/internal/service"
)

// ShopService is satisfied by *service.ShopService.
type ShopService interface {
	Catalog(ctx context.Context) (models.ShopCatalog, error)
	OrderHistory(ctx context.Context, userUUID string) ([]models.ShopOrder, error)
	Checkout(ctx context.Context, userUUID, email string, req models.CheckoutRequest) (models.CheckoutResponse, error)
	ConfirmCheckout(ctx context.Context, userUUID, email string, req models.CheckoutConfirmRequest) (models.CheckoutResponse, error)
}

// ShopHandler exposes the attendee-facing shop endpoints.
type ShopHandler struct {
	shop ShopService
}

// NewShopHandler constructs a ShopHandler.
func NewShopHandler(shop ShopService) *ShopHandler {
	return &ShopHandler{shop: shop}
}

// Items handles GET /shops/items, returning the catalog envelope
// {items, isShopOpen, activeEventId}.
func (h *ShopHandler) Items(c *gin.Context) {
	catalog, err := h.shop.Catalog(c.Request.Context())
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching shop items failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "Error retrieving shop items"})
		return
	}
	c.JSON(http.StatusOK, catalog)
}

// Orders handles GET /shops/orders/me, returning the caller's own orders.
//
// The path is /orders/me, not /orders: the response is scoped to the
// authenticated caller and nothing here can list another user's orders. Naming
// the scope in the path keeps that obvious rather than implicit.
func (h *ShopHandler) Orders(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	orders, err := h.shop.OrderHistory(c.Request.Context(), user.UserID)
	if err != nil {
		slog.ErrorContext(c.Request.Context(), "fetching shop order history failed", "error", err)
		c.JSON(http.StatusInternalServerError, gin.H{"message": "Error retrieving order history"})
		return
	}
	if orders == nil {
		orders = []models.ShopOrder{}
	}
	c.JSON(http.StatusOK, orders)
}

// Checkout handles POST /shops/checkout: it creates a PENDING order, reserves
// its stock, and returns the order id the client then pays against.
//
// A stock shortfall returns 400 with {message, itemId, availableQuantity}. Those
// two extra fields are the contract that lets the client repair the cart itself
// -- it looks up the named line and either clamps it to availableQuantity or
// drops it -- instead of showing an unactionable failure. The same shape carries
// a per-user cap breach, where availableQuantity is the caller's remaining
// allowance.
func (h *ShopHandler) Checkout(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req models.CheckoutRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}
	if err := req.Validate(); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": err.Error()})
		return
	}

	resp, err := h.shop.Checkout(c.Request.Context(), user.UserID, user.Email, req)
	if err != nil {
		var shortfall *repository.ErrStockShortfall
		var unavailable *repository.ErrItemUnavailable
		var limit *repository.ErrPerUserLimit

		switch {
		case errors.As(err, &shortfall):
			c.JSON(http.StatusBadRequest, gin.H{
				"message":           shortfall.Error(),
				"itemId":            shortfall.ItemID,
				"availableQuantity": shortfall.Available,
			})
		case errors.As(err, &limit):
			remaining := max(limit.Limit-limit.Purchased, 0)
			c.JSON(http.StatusBadRequest, gin.H{
				"message":           limit.Error(),
				"itemId":            limit.ItemID,
				"availableQuantity": remaining,
			})
		case errors.As(err, &unavailable):
			// No availableQuantity: the item isn't purchasable at any quantity,
			// and sending 0 would make the client silently drop the line as if
			// it had merely sold out.
			c.JSON(http.StatusBadRequest, gin.H{
				"message": unavailable.Error(),
				"itemId":  unavailable.ItemID,
			})
		case errors.Is(err, repository.ErrShopClosed):
			c.JSON(http.StatusConflict, gin.H{"message": "The shop is closed."})
		default:
			slog.ErrorContext(c.Request.Context(), "shop checkout failed", "error", err)
			c.JSON(http.StatusInternalServerError, gin.H{"message": "Checkout failed"})
		}
		return
	}

	c.JSON(http.StatusOK, resp)
}

// ConfirmCheckout handles POST /shops/checkout/confirm: it verifies the order's
// on-chain payment and marks the order CONFIRMED.
//
// 200 rather than 201 -- unlike checkout this creates nothing, it settles an
// order that already exists. The client drives off the body's orderId either
// way.
//
// 503 when the deployment has no merchant wallet configured: the order is left
// PENDING and untouched, so a client that retries after the deployment is fixed
// settles the same order.
func (h *ShopHandler) ConfirmCheckout(c *gin.Context) {
	user := middleware.UserInfoFromContext(c.Request.Context())
	if user == nil {
		c.JSON(http.StatusUnauthorized, gin.H{"message": "missing authentication"})
		return
	}

	var req models.CheckoutConfirmRequest
	if err := c.ShouldBindJSON(&req); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": "invalid request body"})
		return
	}
	if err := req.Validate(); err != nil {
		c.JSON(http.StatusBadRequest, gin.H{"message": err.Error()})
		return
	}

	resp, err := h.shop.ConfirmCheckout(c.Request.Context(), user.UserID, user.Email, req)
	if err != nil {
		switch {
		case errors.Is(err, repository.ErrNotFound):
			c.JSON(http.StatusBadRequest, gin.H{"message": "Invalid order ID"})
		case errors.Is(err, repository.ErrOrderNotOwned):
			// 403, not 404: the order exists and the caller is authenticated,
			// just not entitled to it.
			c.JSON(http.StatusForbidden, gin.H{"message": "You are not allowed to confirm this order."})
		case errors.Is(err, repository.ErrOrderNotPending):
			// 409: the request was well-formed and authorized, it just lost a
			// race or is a replay of an already-settled order. The legacy
			// service returned 500 here, which read as a server fault.
			c.JSON(http.StatusConflict, gin.H{"message": "This order has already been processed."})
		case errors.Is(err, repository.ErrTxHashAlreadyUsed):
			c.JSON(http.StatusBadRequest, gin.H{"message": "This transaction hash has already been used for another order."})
		case errors.Is(err, service.ErrPaymentVerificationFailed):
			// The wrapped reason goes to the log only; the client gets one
			// opaque message so a caller cannot use the response to iterate
			// toward a transaction that passes.
			slog.WarnContext(c.Request.Context(), "shop payment verification failed",
				"error", err, "orderId", req.OrderID)
			c.JSON(http.StatusBadRequest, gin.H{"message": "Transaction verification failed."})
		case errors.Is(err, service.ErrMasterWalletNotConfigured):
			// 503, not 500: nothing about the request is wrong and nothing on
			// this path will start working on a retry -- the deployment has no
			// merchant wallet, so no payment can be verified against anything.
			// The message names no setting: which knob is unset is not the
			// caller's business, and confirming an unpaid order would be worse
			// than refusing.
			slog.ErrorContext(c.Request.Context(), "shop confirm attempted with no master wallet configured", "error", err)
			c.JSON(http.StatusServiceUnavailable, gin.H{
				"message": "Order confirmation is temporarily unavailable. Your order is unchanged; please try again later.",
			})
		default:
			slog.ErrorContext(c.Request.Context(), "shop checkout confirm failed", "error", err)
			c.JSON(http.StatusInternalServerError, gin.H{"message": "Could not confirm your payment"})
		}
		return
	}

	c.JSON(http.StatusOK, resp)
}
