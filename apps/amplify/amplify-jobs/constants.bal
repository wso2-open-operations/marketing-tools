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

# Component name used in logs and probe bodies.
const string COMPONENT = "amplify-jobs";

# Space label stored on `announcement.space` for announcements sent through Novera.
const string NOVERA_SPACE = "novera";

# `share_request.last_error_code` marker written just before the LinkedIn call. A row read back with it is
# never posted again automatically: the previous attempt may already have posted.
const string PUBLISH_IN_FLIGHT = "PUBLISH_IN_FLIGHT";
