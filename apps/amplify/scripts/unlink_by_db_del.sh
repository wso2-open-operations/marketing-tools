#!/usr/bin/env bash
# Copyright (c) 2026, WSO2 LLC. (https://www.wso2.com).
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
# Local demo helper: deletes a user's LinkedIn connection row from the local database, so the LinkedIn member it
# held is free to link again. Use it when unlink-linkedin-user.sh left a removed row behind: that script only
# marks the row removed, and the unique key on the LinkedIn member still counts it (409 "already connected").
#
#   scripts/unlink_by_db_del.sh ada@example.com
#
# Deletes rows in connection.member_connection for that employee. Local stack only. Nothing else references the row.
# The employee is looked up by email in identity.employee, as unlink-linkedin-user.sh does. Works from any directory.
set -euo pipefail
cd "$(dirname "$0")/.."

email="${1:-}"
if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+$ ]]; then
  echo "usage: $0 <email>" >&2
  exit 2
fi

# The email goes to psql as a variable (:'email'), never into the SQL text. The compose banner goes to stderr; drop it.
if ! ids="$(printf "select employee_id from identity.employee where lower(email) = lower(:'email');\n" |
  scripts/compose.sh exec -T -e EMAIL="$email" postgres sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d amplify -At -v ON_ERROR_STOP=1 -v email="$EMAIL"' 2>/dev/null)"; then
  echo "Could not query the local database (is the stack up? try: make up)" >&2
  exit 1
fi

case "$(printf '%s' "$ids" | grep -c .)" in
  1) employee_id="$ids" ;;
  0) echo "No employee with email $email in the local database (have they signed in to Amplify yet? is the stack up?)" >&2; exit 1 ;;
  *) echo "More than one employee matches $email; refusing to guess." >&2; exit 1 ;;
esac

echo "Deleting LinkedIn connection rows for $email ($employee_id)"
printf "delete from connection.member_connection where employee_id = :'id' returning member_urn, removed_at;\n" |
  scripts/compose.sh exec -T -e ID="$employee_id" postgres sh -c \
    'PGPASSWORD="$POSTGRES_PASSWORD" psql -U postgres -d amplify -At -v ON_ERROR_STOP=1 -v id="$ID"'
echo "Done. Link me should now accept this LinkedIn member."
