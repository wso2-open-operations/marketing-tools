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
	"net/http"
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/models"
)

type fakeAppConfigReader struct {
	configs []models.AppConfig
	err     error
}

func (f *fakeAppConfigReader) List(ctx context.Context) ([]models.AppConfig, error) {
	return f.configs, f.err
}

func newAppConfigTestRouter(h *AppConfigHandler) *gin.Engine {
	r := gin.New()
	r.GET("/app-configs", h.List)
	return r
}

func TestAppConfigHandler_List_Success(t *testing.T) {
	reader := &fakeAppConfigReader{configs: []models.AppConfig{
		{Key: "ATTENDEES_SYNC", Value: "COMPLETED", CreatedBy: "SYSTEM", UpdatedBy: "SYSTEM"},
	}}
	h := NewAppConfigHandler(reader)
	r := newAppConfigTestRouter(h)

	w := doRequest(r, http.MethodGet, "/app-configs", nil)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d, body: %s", w.Code, http.StatusOK, w.Body.String())
	}
	var got []models.AppConfig
	if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if len(got) != 1 || got[0].Key != "ATTENDEES_SYNC" {
		t.Errorf("unexpected response: %+v", got)
	}
}

func TestAppConfigHandler_List_EmptyReturnsEmptyArrayNotNull(t *testing.T) {
	h := NewAppConfigHandler(&fakeAppConfigReader{configs: nil})
	r := newAppConfigTestRouter(h)

	w := doRequest(r, http.MethodGet, "/app-configs", nil)

	if w.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusOK)
	}
	if w.Body.String() != "[]" {
		t.Errorf("body = %q, want empty JSON array", w.Body.String())
	}
}

func TestAppConfigHandler_List_RepoErrorMapsTo500(t *testing.T) {
	h := NewAppConfigHandler(&fakeAppConfigReader{err: errBoom})
	r := newAppConfigTestRouter(h)

	w := doRequest(r, http.MethodGet, "/app-configs", nil)

	if w.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", w.Code, http.StatusInternalServerError)
	}
}
