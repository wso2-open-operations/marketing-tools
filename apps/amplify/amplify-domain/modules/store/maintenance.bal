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

// Daily upkeep entry point for amplify-jobs `POST /maintenance/partitions` (B10): one SECURITY DEFINER
// call (V009) creates token/audit partitions ahead, drops expired token days and audit months past
// retention (each drop audited), purges DONE outbox rows and sweeps expired oauth_state rows.

import ballerinax/postgresql;

# What one maintenance call did.
public type MaintenanceResult record {|
    # New audit months
    int audit_partitions_created;
    # New token days
    int token_partitions_created;
    # Token days dropped by the expiry rule
    int token_partitions_dropped;
    # Audit months dropped past retention
    int audit_partitions_dropped;
    # DONE outbox rows purged
    int outbox_rows_purged;
    # Expired OAuth states removed
    int oauth_states_swept;
|};

# Runs partition maintenance (SQL function messaging.run_partition_maintenance, amplify_jobs only).
#
# + db - Client (`amplify_jobs`)
# + return - Counts, or an error
public isolated function runPartitionMaintenance(postgresql:Client db) returns MaintenanceResult|error {
    string result = check db->queryRow(`SELECT messaging.run_partition_maintenance()::text`);
    return result.fromJsonStringWithType();
}
