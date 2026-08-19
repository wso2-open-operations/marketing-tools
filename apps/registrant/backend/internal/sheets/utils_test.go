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

package sheets

import (
	"testing"
	"time"
)

func TestGetFormattedDateTime_ParsesAsRFC1123Z(t *testing.T) {
	got := GetFormattedDateTime(0)
	if _, err := time.Parse(time.RFC1123Z, got); err != nil {
		t.Fatalf("GetFormattedDateTime(0) = %q is not RFC1123Z: %v", got, err)
	}
}

func TestGetFormattedDateTime_AppliesOffset(t *testing.T) {
	zero, err := time.Parse(time.RFC1123Z, GetFormattedDateTime(0))
	if err != nil {
		t.Fatalf("parse offset=0: %v", err)
	}
	plusFive, err := time.Parse(time.RFC1123Z, GetFormattedDateTime(5))
	if err != nil {
		t.Fatalf("parse offset=5: %v", err)
	}

	diff := plusFive.Sub(zero)
	want := 5 * time.Hour
	tolerance := 2 * time.Second // account for wall-clock drift between the two calls
	if diff < want-tolerance || diff > want+tolerance {
		t.Errorf("offset difference = %v, want ~%v", diff, want)
	}
}
