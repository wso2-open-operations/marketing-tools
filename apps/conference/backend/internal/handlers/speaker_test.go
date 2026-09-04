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

// testEventID is a well-formed eventId. conference_config.id is a uuid column,
// so the handlers reject anything else before it reaches the query.
const testEventID = "523757ce-3be9-4c6b-b95b-68c88f3fa5f9"

type fakeSpeakerReader struct {
	summary    []models.SpeakerSummary
	summaryErr error
	speaker    models.Speaker
	speakerErr error
	lastFilter models.SpeakerFilter
}

func (f *fakeSpeakerReader) GetSpeakerSummary(ctx context.Context, filter models.SpeakerFilter) ([]models.SpeakerSummary, error) {
	f.lastFilter = filter
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
			{ID: "speaker-1", Name: "John Doe"},
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

func TestSpeakerHandler_List_PassesEventIDAndQueryToReader(t *testing.T) {
	reader := &fakeSpeakerReader{summary: []models.SpeakerSummary{}}
	h := NewSpeakerHandler(reader)
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers?eventId="+testEventID+"&q=ada", nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if reader.lastFilter.EventID != testEventID {
		t.Errorf("filter.EventID = %q, want %q", reader.lastFilter.EventID, testEventID)
	}
	if reader.lastFilter.Query != "ada" {
		t.Errorf("filter.Query = %q, want %q", reader.lastFilter.Query, "ada")
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

// testSpeakerID is a syntactically valid UUID; see testSessionID for why the
// :id path can't use a readable placeholder.
const testSpeakerID = "b3d8e5f2-91a4-4c60-8d17-5fa2c7e93b48"

func TestSpeakerHandler_Get_ReturnsSpeaker(t *testing.T) {
	reader := &fakeSpeakerReader{speaker: models.Speaker{ID: testSpeakerID, Name: "John Doe"}}
	h := NewSpeakerHandler(reader)
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers/"+testSpeakerID, nil)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var got models.Speaker
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("failed to unmarshal response: %v", err)
	}
	if got.ID != testSpeakerID {
		t.Errorf("ID = %q, want %q", got.ID, testSpeakerID)
	}
}

func TestSpeakerHandler_Get_NotFoundReturns404(t *testing.T) {
	h := NewSpeakerHandler(&fakeSpeakerReader{speakerErr: repository.ErrNotFound})
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers/"+testSpeakerID, nil)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusNotFound)
	}
}

func TestSpeakerHandler_Get_OtherErrorReturns500(t *testing.T) {
	h := NewSpeakerHandler(&fakeSpeakerReader{speakerErr: errBoom})
	rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers/"+testSpeakerID, nil)

	if rec.Code != http.StatusInternalServerError {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusInternalServerError)
	}
}

// speakers.id is a UUID column, same 22P02-to-500 exposure as /sessions/:id.
func TestSpeakerHandler_Get_NonUUIDReturns400(t *testing.T) {
	h := NewSpeakerHandler(&fakeSpeakerReader{speakerErr: errBoom})

	for _, id := range []string{"events", "me", "b3d8e5f2"} {
		rec := doRequest(newSpeakerTestRouter(h), http.MethodGet, "/speakers/"+id, nil)
		if rec.Code != http.StatusBadRequest {
			t.Errorf("GET /speakers/%q status = %d, want %d", id, rec.Code, http.StatusBadRequest)
		}
	}
}

// ?eventId= is bound as a uuid in the summary query, so a non-UUID value is a
// malformed request -- the same guard GET /speakers/:id applies.
func TestSpeakerHandler_List_NonUUIDEventIDReturns400(t *testing.T) {
	reader := &fakeSpeakerReader{}
	r := newSpeakerTestRouter(NewSpeakerHandler(reader))

	w := doRequest(r, http.MethodGet, "/speakers?eventId=not-a-uuid", nil)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", w.Code, w.Body.String())
	}
	if reader.lastFilter.EventID != "" {
		t.Errorf("repository should not have been called, got %+v", reader.lastFilter)
	}
}
