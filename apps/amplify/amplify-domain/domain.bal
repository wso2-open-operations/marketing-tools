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

// wso2/amplify_domain (ADR-021): the bounded contexts (pure domain + repository ports + PostgreSQL
// repositories) shared by amplify-api and amplify-jobs, plus `store` (client, outbox and audit writers).

# Package name, used in log context.
public const string PACKAGE = "amplify_domain";
