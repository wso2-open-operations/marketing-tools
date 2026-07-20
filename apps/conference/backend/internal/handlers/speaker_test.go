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
	"testing"

	"github.com/gin-gonic/gin"

	"wso2-coin-backend/internal/models"
	"wso2-coin-backend/internal/repository"
)

var errBoom = errors.New("boom")

type fakeSpeakerReader struct {
	summary    []models.SpeakerSummary
	summaryErr error
	speaker    models.Speaker
	speakerErr error
}

func (f *fakeSpeakerReader) GetSpeakerSummary(ctx context.Context) ([]models.SpeakerSummary, error) {
	return f.summary, f.summaryErr
}

func (f *fakeSpeakerReader) GetSpeaker(ctx context.Context, id string) (models.Speaker, error) {
	return f.speaker, f.speakerErr
}

func newSpeakerTestRouter(h *SpeakerHandler) *gin.Engine {
	r := gin.New()
	r.GET("/speakers", h.List)
	r.GET("/speakers/:id", h.Get)
	return r
}

func TestSpeakerHandler_List_ReturnsSummaries(t *testing.T) {
	reader := &fakeSpeakerReader{
		summary: []models.SpeakerSummary{
			{ID: "speaker-1", Name: "Jay Howell", SessionSpeakers: []models.SessionSpeakerWithEvent{}},
		},
	}
	h := NewSpeakerHandler(reader)
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got []models.SpeakerSummary
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if len(got) != 1 || got[0].ID != "speaker-1" {
		t.Errorf("unexpected body: %+v", got)
	}
}

func TestSpeakerHandler_List_EmptyResultReturnsEmptyArrayNotNull(t *testing.T) {
	h := NewSpeakerHandler(&fakeSpeakerReader{summary: nil})
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if body := rec.Body.String(); body != "[]" {
		t.Errorf("body = %q, want %q", body, "[]")
	}
}

func TestSpeakerHandler_List_RepositoryErrorReturns500(t *testing.T) {
	h := NewSpeakerHandler(&fakeSpeakerReader{summaryErr: errBoom})
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}

func TestSpeakerHandler_Get_ReturnsSpeaker(t *testing.T) {
	reader := &fakeSpeakerReader{speaker: models.Speaker{ID: "speaker-1", Name: "Jay Howell"}}
	h := NewSpeakerHandler(reader)
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers/speaker-1", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got models.Speaker
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.ID != "speaker-1" {
		t.Errorf("ID = %q, want %q", got.ID, "speaker-1")
	}
}

func TestSpeakerHandler_Get_NotFoundReturns404(t *testing.T) {
	h := NewSpeakerHandler(&fakeSpeakerReader{speakerErr: repository.ErrNotFound})
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers/missing", nil)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

func TestSpeakerHandler_Get_OtherErrorReturns500(t *testing.T) {
	h := NewSpeakerHandler(&fakeSpeakerReader{speakerErr: errBoom})
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers/speaker-1", nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}
