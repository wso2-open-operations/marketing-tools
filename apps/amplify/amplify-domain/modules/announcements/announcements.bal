// Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
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

// Club space context: Google Chat announcements (schema `announcement`).
// Domain model (M2): types.bal, service.bal, events.bal. PostgreSQL repository: repository.bal (M3).

# Module name, used in log context.
public const string MODULE = "announcements";

# Novera notification `source` for Amplify (1-40 lowercase letters, digits or hyphens).
public const string NOVERA_SOURCE = "amplify";
# Novera's limits for `title` and `body`, in characters.
const int NOVERA_LINE_MAX = 300;
const int NOVERA_BODY_MAX = 5000;
